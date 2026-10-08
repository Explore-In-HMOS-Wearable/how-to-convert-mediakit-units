import { media } from '@kit.MediaKit';
import { image } from '@kit.ImageKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0001;
const TAG: string = 'VideoFrameExtractor';

export enum TimeErrorCode {
  MISSING_DURATION = 'MISSING_DURATION',
  MALFORMED_DURATION = 'MALFORMED_DURATION',
  NON_POSITIVE_DURATION = 'NON_POSITIVE_DURATION',
  NON_FINITE_TIME = 'NON_FINITE_TIME',
  UNSAFE_PRECISION = 'UNSAFE_PRECISION',
  INVALID_COUNT = 'INVALID_COUNT'
}

export class TimeValueError extends Error {
  readonly code: TimeErrorCode;
  readonly rawValue: string;

  constructor(code: TimeErrorCode, message: string, rawValue: string) {
    super(message);
    this.name = 'TimeValueError';
    this.code = code;
    this.rawValue = rawValue;
  }
}

export class ClampResult {
  readonly valueMs: number;
  readonly wasClamped: boolean;
  readonly note: string;

  constructor(valueMs: number, wasClamped: boolean, note: string) {
    this.valueMs = valueMs;
    this.wasClamped = wasClamped;
    this.note = note;
  }
}

export class MediaTime {
  static readonly US_PER_MS: number = 1000;
  static readonly END_GUARD_MS: number = 100;

  static parseDurationMs(raw: string | undefined): number {
    if (raw === undefined || raw.trim().length === 0) {
      throw new TimeValueError(TimeErrorCode.MISSING_DURATION,
        'Metadata has no duration', String(raw));
    }
    const trimmed = raw.trim();
    if (!/^-?\d+(\.\d+)?$/.test(trimmed)) {
      throw new TimeValueError(TimeErrorCode.MALFORMED_DURATION,
        `Duration is not a plain number: "${trimmed}"`, trimmed);
    }
    const valueMs = Number(trimmed);
    if (valueMs <= 0) {
      throw new TimeValueError(TimeErrorCode.NON_POSITIVE_DURATION,
        `Duration ${valueMs} ms is not usable (live stream or unknown length)`, trimmed);
    }
    return Math.round(valueMs);
  }

  static msToUs(ms: number): number {
    if (!Number.isFinite(ms)) {
      throw new TimeValueError(TimeErrorCode.NON_FINITE_TIME,
        `Cannot convert non-finite time: ${ms}`, String(ms));
    }
    const us = Math.round(ms * MediaTime.US_PER_MS);
    if (Math.abs(us) > Number.MAX_SAFE_INTEGER) {
      throw new TimeValueError(TimeErrorCode.UNSAFE_PRECISION,
        `${ms} ms exceeds safe integer range in µs`, String(ms));
    }
    return us;
  }

  static usToMs(us: number): number {
    return Math.floor(us / MediaTime.US_PER_MS);
  }

  static clampToPlayableMs(requestedMs: number, durationMs: number): ClampResult {
    if (!Number.isFinite(requestedMs)) {
      throw new TimeValueError(TimeErrorCode.NON_FINITE_TIME,
        `Requested time is not finite: ${requestedMs}`, String(requestedMs));
    }
    const guardMs = Math.min(MediaTime.END_GUARD_MS, Math.floor(durationMs / 2));
    const lastSafeMs = Math.max(0, durationMs - guardMs);

    if (requestedMs < 0) {
      return new ClampResult(0, true, `${requestedMs} ms is before start, used 0 ms`);
    }
    if (requestedMs > lastSafeMs) {
      return new ClampResult(lastSafeMs, true,
        `${requestedMs} ms is past end, used ${lastSafeMs} ms`);
    }
    return new ClampResult(Math.round(requestedMs), false, '');
  }

  static evenlySpacedTimesMs(durationMs: number, count: number): number[] {
    if (!Number.isInteger(count) || count < 1) {
      throw new TimeValueError(TimeErrorCode.INVALID_COUNT,
        `Frame count must be a positive integer, got ${count}`, String(count));
    }
    const times: number[] = [];
    for (let i = 0; i < count; i++) {
      times.push(Math.round((i + 0.5) * durationMs / count));
    }
    return times;
  }
}

export class ExtractedFrame {
  readonly requestedMs: number;
  readonly resolvedMs: number;
  readonly timeUs: number;
  readonly note: string;
  readonly pixelMap: image.PixelMap;

  constructor(requestedMs: number, clamp: ClampResult, timeUs: number, pixelMap: image.PixelMap) {
    this.requestedMs = requestedMs;
    this.resolvedMs = clamp.valueMs;
    this.timeUs = timeUs;
    this.note = clamp.note;
    this.pixelMap = pixelMap;
  }
}

export class FrameFailure {
  readonly requestedMs: number;
  readonly reason: string;

  constructor(requestedMs: number, reason: string) {
    this.requestedMs = requestedMs;
    this.reason = reason;
  }
}

export class ExtractionReport {
  readonly durationMs: number;
  readonly frames: ExtractedFrame[] = [];
  readonly failures: FrameFailure[] = [];

  constructor(durationMs: number) {
    this.durationMs = durationMs;
  }

  releaseAll(): void {
    for (const f of this.frames) {
      f.pixelMap.release().catch((e: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'PixelMap release failed: %{public}d', e.code);
      });
    }
  }
}

export function describeError(e: Object): string {
  if (e instanceof TimeValueError) {
    return `${e.code}: ${e.message}`;
  }
  const be = e as BusinessError;
  if (be.code !== undefined) {
    return `BusinessError ${be.code}: ${be.message}`;
  }
  return String(e);
}

export class VideoFrameExtractor {
  private readonly fdSrc: media.AVFileDescriptor;

  constructor(fdSrc: media.AVFileDescriptor) {
    this.fdSrc = fdSrc;
  }

  async readDurationMs(): Promise<number> {
    const extractor: media.AVMetadataExtractor = await media.createAVMetadataExtractor();
    try {
      extractor.fdSrc = this.fdSrc;
      const metadata: media.AVMetadata = await extractor.fetchMetadata();
      hilog.info(DOMAIN, TAG, 'Raw duration string: "%{public}s"', String(metadata.duration));
      return MediaTime.parseDurationMs(metadata.duration);
    } finally {
      await VideoFrameExtractor.safeRelease(() => extractor.release(), 'AVMetadataExtractor');
    }
  }

  async extractAt(durationMs: number, timesMs: number[],
    size: media.PixelMapParams): Promise<ExtractionReport> {
    const report = new ExtractionReport(durationMs);
    const generator: media.AVImageGenerator = await media.createAVImageGenerator();
    try {
      generator.fdSrc = this.fdSrc;

      for (const requestedMs of timesMs) {
        try {
          const clamp = MediaTime.clampToPlayableMs(requestedMs, durationMs);
          if (clamp.wasClamped) {
            hilog.warn(DOMAIN, TAG, '%{public}s', clamp.note);
          }
          const timeUs = MediaTime.msToUs(clamp.valueMs); // ms -> µs
          const pixelMap = await VideoFrameExtractor.fetchWithFallback(generator, timeUs, size);
          report.frames.push(new ExtractedFrame(requestedMs, clamp, timeUs, pixelMap));
        } catch (e) {
          const reason = describeError(e as Object);
          hilog.error(DOMAIN, TAG, 'Frame at %{public}s ms failed: %{public}s',
            String(requestedMs), reason);
          report.failures.push(new FrameFailure(requestedMs, reason));
        }
      }
    } finally {
      await VideoFrameExtractor.safeRelease(() => generator.release(), 'AVImageGenerator');
    }
    return report;
  }

  private static async fetchWithFallback(generator: media.AVImageGenerator, timeUs: number,
    size: media.PixelMapParams): Promise<image.PixelMap> {
    try {
      return await generator.fetchFrameByTime(timeUs,
        media.AVImageQueryOptions.AV_IMAGE_QUERY_CLOSEST_SYNC, size);
    } catch (e) {
      const err = e as BusinessError;
      if (err.code === 401) {
        throw Error()
      }
      hilog.warn(DOMAIN, TAG, 'CLOSEST_SYNC failed at %{public}d us (code %{public}d), retrying PREVIOUS_SYNC',
        timeUs, err.code);
      return await generator.fetchFrameByTime(timeUs,
        media.AVImageQueryOptions.AV_IMAGE_QUERY_PREVIOUS_SYNC, size);
    }
  }

  private static async safeRelease(release: () => Promise<void>, name: string): Promise<void> {
    try {
      await release();
    } catch (e) {
      hilog.warn(DOMAIN, TAG, '%{public}s release failed: %{public}s', name, describeError(e as Object));
    }
  }
}
