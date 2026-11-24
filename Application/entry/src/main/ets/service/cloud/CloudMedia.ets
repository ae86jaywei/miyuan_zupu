import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Person, cloudMemberKey } from 'common_base';
import { AccountService } from '../AccountService';

const TAG: string = '[Genealogy][CloudMedia]';

/** 待上传媒体 */
export class MediaJob {
  memberId: string = '';
  uid: string = '';
  bookKey: number = 0;
  uri: string = '';
  /** avatar / photo / video */
  kind: string = '';
  index: number = 0;
  isVideo: boolean = false;
}

/** 已准备好的本地缓存文件 */
export class PreparedFile {
  relName: string = '';
  size: number = 0;
  isVideo: boolean = false;
  /** 是否为临时压缩/拷贝文件，上传后需删除 */
  temporary: boolean = false;

  constructor(relName: string, size: number, isVideo: boolean, temporary: boolean) {
    this.relName = relName;
    this.size = size;
    this.isVideo = isVideo;
    this.temporary = temporary;
  }
}

/**
 * 备份前把图库/视频 URI 整理成可上传任务，并负责端侧压缩与临时文件清理。
 * 纯文件处理，不持有云端状态。
 */
export class CloudMedia {
  /** 按人物收集头像/照片/视频上传任务，自动去重 */
  static collect(people: Person[], bookKey: number): MediaJob[] {
    const jobs: MediaJob[] = [];
    const seen: Set<string> = new Set<string>();
    for (let i: number = 0; i < people.length; i++) {
      const person: Person = people[i];
      const memberId: string = cloudMemberKey(bookKey, person.uid);
      const avatar: string = person.avatar !== undefined ? person.avatar : '';
      if (avatar.length > 0 && !avatar.startsWith('cloud://')) {
        const key: string = memberId + '|' + avatar;
        if (!seen.has(key)) {
          seen.add(key);
          const job: MediaJob = new MediaJob();
          job.memberId = memberId;
          job.uid = person.uid;
          job.bookKey = bookKey;
          job.uri = avatar;
          job.kind = 'avatar';
          job.index = 0;
          job.isVideo = false;
          jobs.push(job);
        }
      }
      const photos: string[] = CloudMedia.splitUris(person.photos);
      for (let p: number = 0; p < photos.length; p++) {
        const uri: string = photos[p];
        if (uri.length === 0 || uri.startsWith('cloud://')) {
          continue;
        }
        const key: string = memberId + '|' + uri;
        if (seen.has(key)) {
          continue;
        }
        seen.add(key);
        const job: MediaJob = new MediaJob();
        job.memberId = memberId;
        job.uid = person.uid;
        job.bookKey = bookKey;
        job.uri = uri;
        job.kind = 'photo';
        job.index = p;
        job.isVideo = CloudMedia.isVideoUri(uri);
        jobs.push(job);
      }
      const videos: string[] = CloudMedia.splitUris(person.videos);
      for (let v: number = 0; v < videos.length; v++) {
        const uri: string = videos[v];
        if (uri.length === 0 || uri.startsWith('cloud://')) {
          continue;
        }
        const key: string = memberId + '|' + uri;
        if (seen.has(key)) {
          continue;
        }
        seen.add(key);
        const job: MediaJob = new MediaJob();
        job.memberId = memberId;
        job.uid = person.uid;
        job.bookKey = bookKey;
        job.uri = uri;
        job.kind = 'video';
        job.index = v;
        job.isVideo = true;
        jobs.push(job);
      }
    }
    return jobs;
  }

  static splitUris(value: string): string[] {
    const list: string[] = [];
    if (value === undefined || value.length === 0) {
      return list;
    }
    const parts: string[] = value.split(';');
    for (let i: number = 0; i < parts.length; i++) {
      if (parts[i].length > 0) {
        list.push(parts[i]);
      }
    }
    return list;
  }

  static fileNameOf(uri: string): string {
    let name: string = uri;
    const queryIndex: number = name.indexOf('?');
    if (queryIndex >= 0) {
      name = name.substring(0, queryIndex);
    }
    const slash: number = name.lastIndexOf('/');
    if (slash >= 0) {
      name = name.substring(slash + 1);
    }
    return name;
  }

  static extensionOf(uri: string): string {
    const name: string = CloudMedia.fileNameOf(uri);
    const dot: number = name.lastIndexOf('.');
    if (dot >= 0 && dot < name.length - 1) {
      return name.substring(dot + 1).toLowerCase();
    }
    return '';
  }

  static isVideoUri(uri: string): boolean {
    const ext: string = CloudMedia.extensionOf(uri);
    return ext === 'mp4' || ext === 'mov' || ext === 'm4v' || ext === 'avi'
      || ext === 'mkv' || ext === '3gp' || ext === 'webm';
  }

  /** 把图库 URI 复制/压缩到 cacheDir，返回可上传的相对路径 */
  static async prepare(job: MediaJob): Promise<PreparedFile | null> {
    const context: common.UIAbilityContext | null = AccountService.getInstance().getContext();
    if (context === null) {
      return null;
    }
    const cacheDir: string = context.cacheDir;
    if (job.uri.startsWith(cacheDir + '/')) {
      try {
        const stat: fileIo.Stat = fileIo.statSync(job.uri);
        return new PreparedFile(job.uri.substring(cacheDir.length + 1), stat.size, job.isVideo, false);
      } catch (err) {
        return null;
      }
    }
    const ext: string = CloudMedia.extensionOf(job.uri);
    const stamp: number = Date.now();
    const prefix: string = job.kind === 'avatar' ? 'avatar' : 'media';
    // 缓存文件名中不能使用 #（云端成员ID分隔符），改用族谱前缀区隔
    const fileId: string = job.bookKey > 0
      ? 'b' + job.bookKey.toString() + '_' + job.uid
      : job.uid;
    const base: string = fileId + '_' + prefix + '_' + job.index + '_' + stamp;
    if (!job.isVideo) {
      const jpegName: string = base + '.jpg';
      const jpegPath: string = cacheDir + '/' + jpegName;
      const compressed: boolean = await CloudMedia.compressImage(job.uri, jpegPath);
      if (compressed) {
        try {
          const st: fileIo.Stat = fileIo.statSync(jpegPath);
          return new PreparedFile(jpegName, st.size, false, true);
        } catch (err) {
          hilog.warn(0x0000, TAG, 'stat compressed file failed');
        }
      }
    }
    const rawName: string = base + (ext.length > 0 ? '.' + ext : '');
    const rawPath: string = cacheDir + '/' + rawName;
    let srcFile: fileIo.File | null = null;
    let dstFile: fileIo.File | null = null;
    try {
      srcFile = fileIo.openSync(job.uri, fileIo.OpenMode.READ_ONLY);
      dstFile = fileIo.openSync(rawPath,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.copyFileSync(srcFile.fd, dstFile.fd);
      const st: fileIo.Stat = fileIo.statSync(rawPath);
      return new PreparedFile(rawName, st.size, job.isVideo, true);
    } catch (err) {
      hilog.warn(0x0000, TAG, 'copy media failed: %{public}s', JSON.stringify(err));
      return null;
    } finally {
      if (srcFile !== null) {
        try {
          fileIo.closeSync(srcFile);
        } catch (err) {
          hilog.warn(0x0000, TAG, 'close src failed');
        }
      }
      if (dstFile !== null) {
        try {
          fileIo.closeSync(dstFile);
        } catch (err) {
          hilog.warn(0x0000, TAG, 'close dst failed');
        }
      }
    }
  }

  /** 端侧图片压缩：长边不超过 1920px，JPEG 质量 80 */
  static async compressImage(uri: string, dstPath: string): Promise<boolean> {
    let srcFile: fileIo.File | null = null;
    let source: image.ImageSource | null = null;
    let pixelMap: image.PixelMap | null = null;
    let packer: image.ImagePacker | null = null;
    let dstFile: fileIo.File | null = null;
    try {
      srcFile = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      source = image.createImageSource(srcFile.fd);
      const info: image.ImageInfo = await source.getImageInfo();
      const width: number = info.size.width;
      const height: number = info.size.height;
      if (width <= 0 || height <= 0) {
        return false;
      }
      const maxSide: number = Math.max(width, height);
      let targetWidth: number = width;
      let targetHeight: number = height;
      if (maxSide > 1920) {
        const scale: number = 1920 / maxSide;
        targetWidth = Math.max(1, Math.round(width * scale));
        targetHeight = Math.max(1, Math.round(height * scale));
      }
      const decodeOptions: image.DecodingOptions = {
        desiredSize: { width: targetWidth, height: targetHeight }
      };
      pixelMap = await source.createPixelMap(decodeOptions);
      packer = image.createImagePacker();
      const packOptions: image.PackingOption = { format: 'image/jpeg', quality: 80 };
      const data: ArrayBuffer = await packer.packToData(pixelMap, packOptions);
      dstFile = fileIo.openSync(dstPath,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(dstFile.fd, data);
      return true;
    } catch (err) {
      hilog.warn(0x0000, TAG, 'compress image failed: %{public}s', JSON.stringify(err));
      return false;
    } finally {
      if (dstFile !== null) {
        try {
          fileIo.closeSync(dstFile);
        } catch (err) {
          hilog.warn(0x0000, TAG, 'close compressed file failed');
        }
      }
      if (packer !== null) {
        try {
          await packer.release();
        } catch (err) {
          hilog.warn(0x0000, TAG, 'release packer failed');
        }
      }
      if (pixelMap !== null) {
        try {
          await pixelMap.release();
        } catch (err) {
          hilog.warn(0x0000, TAG, 'release pixelMap failed');
        }
      }
      if (source !== null) {
        try {
          await source.release();
        } catch (err) {
          hilog.warn(0x0000, TAG, 'release image source failed');
        }
      }
      if (srcFile !== null) {
        try {
          fileIo.closeSync(srcFile);
        } catch (err) {
          hilog.warn(0x0000, TAG, 'close image src failed');
        }
      }
    }
  }

  static removeCacheFile(prepared: PreparedFile): void {
    if (!prepared.temporary) {
      return;
    }
    const context: common.UIAbilityContext | null = AccountService.getInstance().getContext();
    if (context === null) {
      return;
    }
    try {
      fileIo.unlinkSync(context.cacheDir + '/' + prepared.relName);
    } catch (err) {
      hilog.warn(0x0000, TAG, 'remove cache file failed');
    }
  }
}
