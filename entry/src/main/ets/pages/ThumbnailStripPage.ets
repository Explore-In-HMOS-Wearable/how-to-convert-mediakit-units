import { media } from '@kit.MediaKit';
import { common } from '@kit.AbilityKit';
import { resourceManager } from '@kit.LocalizationKit';
import { display } from '@kit.ArkUI';
import {
  VideoFrameExtractor, MediaTime, ExtractionReport, ExtractedFrame, FrameFailure, describeError
} from '../common/VideoFrameExtractor';
import { hilog } from '@kit.PerformanceAnalysisKit';

const VIDEO_FILE: string = 'sample.mp4';
const FRAME_COUNT: number = 3;
const INCLUDE_EDGE_CASES: boolean = true;
const THUMB_WIDTH_RATIO: number = 0.8;
const TAG = 'App'

enum LoadState { LOADING, READY, ERROR }

function formatClock(ms: number): string {
  const safeMs = Math.max(0, Math.floor(ms));
  const millis = safeMs % 1000;
  const totalS = Math.floor(safeMs / 1000);
  const s = totalS % 60;
  const totalM = Math.floor(totalS / 60);
  const m = totalM % 60;
  const h = Math.floor(totalM / 60);

  const ss = s.toString().padStart(2, '0');
  const mmm = millis.toString().padStart(3, '0');
  return h > 0
    ? `${h}:${m.toString().padStart(2, '0')}:${ss}.${mmm}`
    : `${m}:${ss}.${mmm}`;
}

@Entry
@Component
struct ThumbnailStripPage {
  @State loadState: LoadState = LoadState.LOADING;
  @State message: string = '';
  @State frames: ExtractedFrame[] = [];
  @State failures: FrameFailure[] = [];
  @State thumbWidthVp: number = 160;
  @State thumbHeightVp: number = 90;
  private decodeSize: media.PixelMapParams = { width: 320, height: 180 };
  private report?: ExtractionReport;

  aboutToAppear(): void {
    this.computeThumbSize();
    this.load();
  }

  aboutToDisappear(): void {
    this.report?.releaseAll();
  }

  private computeThumbSize(): void {
    try {
      const d = display.getDefaultDisplaySync();
      const screenPx = Math.min(d.width, d.height);
      const widthPx = Math.round(screenPx * THUMB_WIDTH_RATIO);
      const heightPx = Math.round(widthPx * 9 / 16);
      this.decodeSize = { width: widthPx, height: heightPx };
      this.thumbWidthVp = this.getUIContext().px2vp(widthPx);
      this.thumbHeightVp = this.getUIContext().px2vp(heightPx);
    } catch (e) {
      hilog.warn(0x0001, TAG, 'Default values are used')
    }
  }

  private fail(message: string): void {
    this.message = message;
    this.loadState = LoadState.ERROR;
  }

  private async load(): Promise<void> {
    if (!canIUse('SystemCapability.Multimedia.Media.AVMetadataExtractor') ||
      !canIUse('SystemCapability.Multimedia.Media.AVImageGenerator')) {
      this.fail('Frame extraction is not supported on this device');
      return;
    }

    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    let rawFd: resourceManager.RawFileDescriptor | undefined = undefined;

    try {
      rawFd = await ctx.resourceManager.getRawFd(VIDEO_FILE);
      const fdSrc: media.AVFileDescriptor = {
        fd: rawFd.fd, offset: rawFd.offset, length: rawFd.length
      };
      const extractor = new VideoFrameExtractor(fdSrc);

      const durationMs = await extractor.readDurationMs();
      const timesMs: number[] = MediaTime.evenlySpacedTimesMs(durationMs, FRAME_COUNT);
      if (INCLUDE_EDGE_CASES) {
        timesMs.push(-500);
        timesMs.push(durationMs + 10000);
        timesMs.push(Number.NaN);
      }

      this.report = await extractor.extractAt(durationMs, timesMs, this.decodeSize);
      this.frames = this.report.frames;
      this.failures = this.report.failures;

      if (this.frames.length === 0) {
        this.fail('No frames could be extracted');
      } else {
        this.loadState = LoadState.READY;
      }
    } catch (e) {
      this.fail(describeError(e as Object));
    } finally {
      if (rawFd !== undefined) {
        try {
          ctx.resourceManager.closeRawFdSync(VIDEO_FILE);
        } catch (e) {
          hilog.info(0x001,TAG,'File already open')
        }
      }
    }
  }

  @Builder
  FramePage(f: ExtractedFrame) {
    Column({ space: 6 }) {
      Text(formatClock(f.resolvedMs))
        .fontSize(20).fontWeight(FontWeight.Medium).fontColor(Color.White)
      Image(f.pixelMap)
        .width(this.thumbWidthVp).height(this.thumbHeightVp)
        .objectFit(ImageFit.Contain).borderRadius(8)
      Text(`${f.resolvedMs} ms → ${f.timeUs} µs`)
        .fontSize(11).fontColor($r('sys.color.node_graph_toolbar_background_color'))
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('80%').textAlign(TextAlign.Center)
      if (f.note.length > 0) {
        Text(`adjusted from ${f.requestedMs} ms`)
          .fontSize(11).fontColor('#FFB347')
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('70%').textAlign(TextAlign.Center)
      }
    }
    .width('100%').height('100%')
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  FailurePage() {
    Column({ space: 6 }) {
      Text(`${this.failures.length} failed`)
        .fontSize(18).fontWeight(FontWeight.Medium).fontColor('#FF6B6B')
      ForEach(this.failures, (f: FrameFailure) => {
        Column() {
          Text(`${f.requestedMs} ms`).fontSize(13).fontColor(Color.White)
          Text(f.reason.split(':')[0]).fontSize(11).fontColor($r('sys.color.node_graph_toolbar_background_color'))
        }
      }, (f: FrameFailure, i: number) => f.requestedMs.toString())
    }
    .width('70%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }

  build() {
    Stack() {
      if (this.loadState === LoadState.LOADING) {
        Column({ space: 8 }) {
          LoadingProgress().width(48).height(48).color(Color.White)
          Text('Extracting…').fontSize(14).fontColor(Color.White)
        }
      } else if (this.loadState === LoadState.ERROR) {
        Column({ space: 6 }) {
          Text('!').fontSize(28).fontWeight(FontWeight.Bold).fontColor('#FF6B6B')
          Text(this.message)
            .fontSize(13).fontColor(Color.White).textAlign(TextAlign.Center)
            .maxLines(4).textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('70%')
      } else {
        Swiper() {
          ForEach(this.frames, (f: ExtractedFrame) => {
            this.FramePage(f)
          }, (f: ExtractedFrame, i: number) => f.requestedMs.toString())
          if (this.failures.length > 0) {
            this.FailurePage()
          }
        }
        .loop(false)
        .indicator(new DotIndicator()
          .itemWidth(6).itemHeight(6)
          .selectedItemWidth(6).selectedItemHeight(6)
          .color('#55FFFFFF').selectedColor(Color.White))
        .width('100%').height('100%')
      }
    }
    .width('100%').height('100%')
    .backgroundColor(Color.Black)
  }
}
