import { cloudDatabase, cloudStorage } from '@kit.CloudFoundationKit';
import { common } from '@kit.AbilityKit';
import { BusinessError, request } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { util } from '@kit.ArkTS';
import { preferences } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Person } from '../model/Person';
import { Genealogy } from '../model/Genealogy';
import { GenealogyService } from './GenealogyService';
import { GenealogyStore } from '../store/GenealogyStore';
import { AccountService } from './AccountService';
import {
  BackupResult,
  CloudFamilyMedia,
  CloudFamilyMember,
  CloudUsage,
  RestoreResult,
  cloudMemberToPerson,
  personToCloudMember
} from '../model/CloudModels';

const TAG: string = '[Genealogy][Cloud]';
const ZONE_NAME: string = 'miyuanzupu';
const BOOK_CLOUD_NAME: string = 'book.json';
const MAX_VIDEO_BYTES: number = 500 * 1024 * 1024;
const MAX_LIST: number = 1000;

/** 同步进度回调 */
export type SyncProgress = (message: string, done: number, total: number) => void;

/** 待上传媒体 */
class MediaJob {
  memberId: string = '';
  uri: string = '';
  kind: string = 'photo';
  index: number = 0;
  isVideo: boolean = false;
}

/** 已准备好的本地缓存文件 */
class PreparedFile {
  relName: string = '';
  size: number = 0;
  isVideo: boolean = false;
  temporary: boolean = false;

  constructor(relName: string, size: number, isVideo: boolean, temporary: boolean) {
    this.relName = relName;
    this.size = size;
    this.isVideo = isVideo;
    this.temporary = temporary;
  }
}

/**
 * 云同步服务（单例）。
 *
 * 数据分层：
 * - 结构化族谱数据 → Cloud DB（FamilyMember）
 * - 图片/视频索引 → Cloud DB（FamilyMedia）
 * - 图片/视频本体 → Cloud Storage（路径包含 userId）
 *
 * 上传严格遵循“先文件、后记录”：Cloud Storage 成功拿到 cloudPath 后才写入 FamilyMedia。
 */
export class CloudSyncService {
  private static instance: CloudSyncService | null = null;

  private zone: cloudDatabase.DatabaseZone | null = null;
  private bucket: cloudStorage.StorageBucket | null = null;
  private prefs: preferences.Preferences | null = null;
  /** 本地媒体 URI → 云端路径，避免重复上传 */
  private uriMap: Map<string, string> = new Map<string, string>();

  static getInstance(): CloudSyncService {
    if (CloudSyncService.instance === null) {
      CloudSyncService.instance = new CloudSyncService();
    }
    return CloudSyncService.instance;
  }

  /** 初始化本地去重表（幂等） */
  init(context: common.UIAbilityContext): void {
    if (this.prefs !== null) {
      return;
    }
    try {
      const opt: preferences.Options = { name: 'zupu_cloud_map' };
      this.prefs = preferences.getPreferencesSync(context, opt);
      const text: string = this.prefs.getSync('map', '') as string;
      if (text.length > 0) {
        const raw: Record<string, string> = JSON.parse(text) as Record<string, string>;
        const keys: string[] = Object.keys(raw);
        for (let i: number = 0; i < keys.length; i++) {
          this.uriMap.set(keys[i], raw[keys[i]]);
        }
      }
    } catch (err) {
      hilog.warn(0x0000, TAG, 'load uri map failed: %{public}s', JSON.stringify(err));
    }
  }

  isReady(): boolean {
    return AccountService.getInstance().isCloudReady();
  }

  private ensureReady(): void {
    if (!this.isReady()) {
      const message: string = AccountService.getInstance().getCloudMessage();
      throw new Error(message.length > 0 ? message : '云服务未就绪，请先登录华为账号');
    }
  }

  private ensureZone(): cloudDatabase.DatabaseZone {
    if (this.zone === null) {
      this.zone = cloudDatabase.zone(ZONE_NAME);
    }
    return this.zone;
  }

  private ensureBucket(): cloudStorage.StorageBucket {
    if (this.bucket === null) {
      this.bucket = cloudStorage.bucket();
    }
    return this.bucket;
  }

  private saveUriMap(): void {
    if (this.prefs === null) {
      return;
    }
    try {
      const obj: Record<string, string> = {};
      this.uriMap.forEach((value: string, key: string) => {
        obj[key] = value;
      });
      this.prefs.putSync('map', JSON.stringify(obj));
      this.prefs.flush();
    } catch (err) {
      hilog.warn(0x0000, TAG, 'save uri map failed: %{public}s', JSON.stringify(err));
    }
  }

  // ============================ 上传备份 ============================

  /** 备份全部族谱数据到云端 */
  async backupAll(progress: SyncProgress): Promise<BackupResult> {
    this.ensureReady();
    const account: AccountService = AccountService.getInstance();
    const userId: string = account.getUserId();
    if (userId.length === 0) {
      throw new Error('请先登录华为账号');
    }
    const zone: cloudDatabase.DatabaseZone = this.ensureZone();
    const people: Person[] = GenealogyService.getInstance().getPeopleCopy();
    const result: BackupResult = new BackupResult();

    // 1. 成员结构化数据
    const docs: CloudFamilyMember[] = [];
    for (let i: number = 0; i < people.length; i++) {
      docs.push(personToCloudMember(people[i], userId));
    }
    const batchSize: number = 20;
    for (let start: number = 0; start < docs.length; start += batchSize) {
      const end: number = Math.min(start + batchSize, docs.length);
      const batch: CloudFamilyMember[] = docs.slice(start, end);
      await zone.upsert(batch);
      result.memberCount += batch.length;
      progress('正在上传族谱成员', result.memberCount, docs.length + 1);
    }

    // 2. 媒体文件
    const existing: CloudFamilyMedia[] = await this.queryAllMedia(userId);
    const existingNames: Set<string> = new Set<string>();
    for (let i: number = 0; i < existing.length; i++) {
      const item: CloudFamilyMedia = existing[i];
      const memberId: string = item.memberId !== undefined ? item.memberId : '';
      const fileName: string = item.fileName !== undefined ? item.fileName : '';
      existingNames.add(memberId + '|' + fileName);
    }

    const jobs: MediaJob[] = this.collectMediaJobs(people);
    progress('正在上传照片与视频', 0, jobs.length);
    for (let i: number = 0; i < jobs.length; i++) {
      const job: MediaJob = jobs[i];
      const mapKey: string = job.memberId + '|' + job.uri;
      if (this.uriMap.has(mapKey)) {
        result.mediaSkipped++;
        progress('正在上传照片与视频', i + 1, jobs.length);
        continue;
      }
      const localName: string = this.fileNameOf(job.uri);
      if (localName.length > 0 && existingNames.has(job.memberId + '|' + localName)) {
        result.mediaSkipped++;
        progress('正在上传照片与视频', i + 1, jobs.length);
        continue;
      }
      const prepared: PreparedFile | null = await this.prepareMedia(job);
      if (prepared === null) {
        result.mediaSkipped++;
        result.warnings.push('已跳过无法读取的媒体：' + localName);
        progress('正在上传照片与视频', i + 1, jobs.length);
        continue;
      }
      if (prepared.size > MAX_VIDEO_BYTES) {
        this.removeCacheFile(prepared);
        result.mediaSkipped++;
        result.warnings.push('视频超过 500MB 限制，已跳过：' + localName);
        progress('正在上传照片与视频', i + 1, jobs.length);
        continue;
      }
      const cloudPath: string = userId + '/' + job.memberId + '/' + prepared.relName;
      try {
        await this.uploadCacheFile(prepared.relName, cloudPath);
        const record: CloudFamilyMedia = new CloudFamilyMedia();
        record.mediaId = util.generateRandomUUID();
        record.userId = userId;
        record.memberId = job.memberId;
        record.type = prepared.isVideo ? 'video' : 'image';
        record.cloudPath = cloudPath;
        record.fileName = prepared.relName;
        record.size = prepared.size;
        record.uploadedAt = Date.now();
        record.deleted = false;
        await zone.upsert(record);
        this.uriMap.set(mapKey, cloudPath);
        result.mediaUploaded++;
      } catch (err) {
        const be: BusinessError = err as BusinessError;
        result.mediaSkipped++;
        result.warnings.push('上传失败：' + localName + '（' + (be.message !== undefined ? be.message : '网络异常') + '）');
        hilog.error(0x0000, TAG, 'upload media failed: %{public}s', JSON.stringify(err));
      } finally {
        this.removeCacheFile(prepared);
      }
      progress('正在上传照片与视频', i + 1, jobs.length);
    }

    // 3. 族谱元信息（谱名、字派、谱序等）
    progress('正在上传族谱信息', docs.length, docs.length + 1);
    await this.backupBook(userId);
    this.saveUriMap();
    progress('备份完成', docs.length + 1, docs.length + 1);
    return result;
  }

  private collectMediaJobs(people: Person[]): MediaJob[] {
    const jobs: MediaJob[] = [];
    const seen: Set<string> = new Set<string>();
    for (let i: number = 0; i < people.length; i++) {
      const person: Person = people[i];
      const avatar: string = person.avatar !== undefined ? person.avatar : '';
      if (avatar.length > 0 && !avatar.startsWith('cloud://')) {
        const key: string = person.uid + '|' + avatar;
        if (!seen.has(key)) {
          seen.add(key);
          const job: MediaJob = new MediaJob();
          job.memberId = person.uid;
          job.uri = avatar;
          job.kind = 'avatar';
          job.index = 0;
          job.isVideo = false;
          jobs.push(job);
        }
      }
      const photos: string[] = this.splitUris(person.photos);
      for (let p: number = 0; p < photos.length; p++) {
        const uri: string = photos[p];
        if (uri.length === 0 || uri.startsWith('cloud://')) {
          continue;
        }
        const key: string = person.uid + '|' + uri;
        if (seen.has(key)) {
          continue;
        }
        seen.add(key);
        const job: MediaJob = new MediaJob();
        job.memberId = person.uid;
        job.uri = uri;
        job.kind = 'photo';
        job.index = p;
        job.isVideo = this.isVideoUri(uri);
        jobs.push(job);
      }
      const videos: string[] = this.splitUris(person.videos);
      for (let v: number = 0; v < videos.length; v++) {
        const uri: string = videos[v];
        if (uri.length === 0 || uri.startsWith('cloud://')) {
          continue;
        }
        const key: string = person.uid + '|' + uri;
        if (seen.has(key)) {
          continue;
        }
        seen.add(key);
        const job: MediaJob = new MediaJob();
        job.memberId = person.uid;
        job.uri = uri;
        job.kind = 'video';
        job.index = v;
        job.isVideo = true;
        jobs.push(job);
      }
    }
    return jobs;
  }

  private splitUris(value: string): string[] {
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

  private fileNameOf(uri: string): string {
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

  private extensionOf(uri: string): string {
    const name: string = this.fileNameOf(uri);
    const dot: number = name.lastIndexOf('.');
    if (dot >= 0 && dot < name.length - 1) {
      return name.substring(dot + 1).toLowerCase();
    }
    return '';
  }

  private isVideoUri(uri: string): boolean {
    const ext: string = this.extensionOf(uri);
    return ext === 'mp4' || ext === 'mov' || ext === 'm4v' || ext === 'avi'
      || ext === 'mkv' || ext === '3gp' || ext === 'webm';
  }

  /** 把图库 URI 复制/压缩到 cacheDir，返回可上传的相对路径 */
  private async prepareMedia(job: MediaJob): Promise<PreparedFile | null> {
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
    const ext: string = this.extensionOf(job.uri);
    const stamp: number = Date.now();
    const prefix: string = job.kind === 'avatar' ? 'avatar' : 'media';
    const base: string = job.memberId + '_' + prefix + '_' + job.index + '_' + stamp;
    if (!job.isVideo) {
      const jpegName: string = base + '.jpg';
      const jpegPath: string = cacheDir + '/' + jpegName;
      const compressed: boolean = await this.compressImage(job.uri, jpegPath);
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
  private async compressImage(uri: string, dstPath: string): Promise<boolean> {
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
      const data: ArrayBuffer = await packer.packing(pixelMap, packOptions);
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

  private removeCacheFile(prepared: PreparedFile): void {
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

  private uploadCacheFile(relName: string, cloudPath: string): Promise<void> {
    const context: common.UIAbilityContext | null = AccountService.getInstance().getContext();
    if (context === null) {
      return Promise.reject(new Error('应用上下文未初始化'));
    }
    const bucket: cloudStorage.StorageBucket = this.ensureBucket();
    return new Promise<void>((resolve, reject) => {
      bucket.uploadFile(context, {
        localPath: relName,
        cloudPath: cloudPath,
        mode: request.agent.Mode.BACKGROUND
      }).then((task: request.agent.Task) => {
        task.on('completed', () => {
          resolve();
        });
        task.on('failed', () => {
          reject(new Error('云端文件上传失败'));
        });
        task.start((err: BusinessError) => {
          if (err) {
            reject(err);
          }
        });
      }).catch((err: BusinessError) => {
        reject(err);
      });
    });
  }

  private downloadCacheFile(cloudPath: string, relName: string): Promise<string> {
    const context: common.UIAbilityContext | null = AccountService.getInstance().getContext();
    if (context === null) {
      return Promise.reject(new Error('应用上下文未初始化'));
    }
    const bucket: cloudStorage.StorageBucket = this.ensureBucket();
    return new Promise<string>((resolve, reject) => {
      bucket.downloadFile(context, {
        localPath: relName,
        cloudPath: cloudPath,
        overwrite: true
      }).then((task: request.agent.Task) => {
        task.on('completed', () => {
          resolve(context.cacheDir + '/' + relName);
        });
        task.on('failed', () => {
          reject(new Error('云端文件下载失败'));
        });
        task.start((err: BusinessError) => {
          if (err) {
            reject(err);
          }
        });
      }).catch((err: BusinessError) => {
        reject(err);
      });
    });
  }

  /** 备份族谱元信息为 JSON 文件 */
  private async backupBook(userId: string): Promise<void> {
    const context: common.UIAbilityContext | null = AccountService.getInstance().getContext();
    if (context === null) {
      return;
    }
    const book: Genealogy = GenealogyService.getInstance().getBook();
    const relName: string = 'zupu_book.json';
    const path: string = context.cacheDir + '/' + relName;
    try {
      const file: fileIo.File = fileIo.openSync(path,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, JSON.stringify(book));
      fileIo.closeSync(file);
      await this.uploadCacheFile(relName, userId + '/' + BOOK_CLOUD_NAME);
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      hilog.warn(0x0000, TAG, 'backup book failed: %{public}s', be.message);
    } finally {
      try {
        fileIo.unlinkSync(path);
      } catch (err) {
        hilog.warn(0x0000, TAG, 'remove book cache failed');
      }
    }
  }

  // ============================ 换机恢复 ============================

  /** 从云端恢复族谱：结构数据全量恢复，图片按需下载，视频仅恢复引用 */
  async restoreAll(progress: SyncProgress): Promise<RestoreResult> {
    this.ensureReady();
    const userId: string = AccountService.getInstance().getUserId();
    if (userId.length === 0) {
      throw new Error('请先登录华为账号');
    }
    const result: RestoreResult = new RestoreResult();
    progress('正在读取云端族谱', 0, 1);

    const members: CloudFamilyMember[] = await this.queryAllMembers(userId);
    if (members.length === 0) {
      throw new Error('云端暂无该账号的族谱数据');
    }
    const mediaList: CloudFamilyMedia[] = await this.queryAllMedia(userId);

    const mediaByMember: Map<string, CloudFamilyMedia[]> = new Map<string, CloudFamilyMedia[]>();
    for (let i: number = 0; i < mediaList.length; i++) {
      const item: CloudFamilyMedia = mediaList[i];
      const memberId: string = item.memberId !== undefined ? item.memberId : '';
      if (memberId.length === 0) {
        continue;
      }
      let bucketList: CloudFamilyMedia[] | undefined = mediaByMember.get(memberId);
      if (bucketList === undefined) {
        bucketList = [];
        mediaByMember.set(memberId, bucketList);
      }
      bucketList.push(item);
    }

    // 先下载图片到缓存，视频保留 cloud:// 引用，点击时再下载
    const imageLocal: Map<string, string> = new Map<string, string>();
    const totalSteps: number = mediaList.length + members.length + 1;
    let done: number = 0;
    for (let i: number = 0; i < mediaList.length; i++) {
      const item: CloudFamilyMedia = mediaList[i];
      const type: string = item.type !== undefined ? item.type : 'image';
      const cloudPath: string = item.cloudPath !== undefined ? item.cloudPath : '';
      const fileName: string = item.fileName !== undefined ? item.fileName : '';
      if (type === 'image' && cloudPath.length > 0 && fileName.length > 0) {
        try {
          const localPath: string = await this.downloadCacheFile(cloudPath, fileName);
          imageLocal.set(cloudPath, localPath);
          result.imageDownloaded++;
        } catch (err) {
          result.warnings.push('图片下载失败：' + fileName);
        }
      } else if (type === 'video') {
        result.videoDeferred++;
      }
      done++;
      progress('正在恢复照片', done, totalSteps);
    }

    const persons: Person[] = [];
    for (let i: number = 0; i < members.length; i++) {
      const person: Person = cloudMemberToPerson(members[i]);
      const items: CloudFamilyMedia[] | undefined = mediaByMember.get(person.uid);
      if (items !== undefined) {
        let avatar: string = '';
        const photos: string[] = [];
        for (let j: number = 0; j < items.length; j++) {
          const media: CloudFamilyMedia = items[j];
          const cloudPath: string = media.cloudPath !== undefined ? media.cloudPath : '';
          const fileName: string = media.fileName !== undefined ? media.fileName : '';
          const type: string = media.type !== undefined ? media.type : 'image';
          if (type === 'video') {
            photos.push('cloud://' + cloudPath);
            continue;
          }
          const local: string | undefined = imageLocal.get(cloudPath);
          const storagePath: string = local !== undefined ? local : 'cloud://' + cloudPath;
          if (fileName.startsWith(person.uid + '_avatar_')) {
            avatar = storagePath;
          } else {
            photos.push(storagePath);
          }
        }
        if (avatar.length > 0) {
          person.avatar = avatar;
        }
        if (photos.length > 0) {
          person.photos = photos.join(';');
        }
      }
      persons.push(person);
      done++;
      progress('正在恢复族谱成员', done, totalSteps);
    }

    await GenealogyService.getInstance().replaceAll(persons);
    GenealogyStore.notifyChanged();
    result.memberCount = persons.length;

    await this.restoreBook(userId);
    progress('恢复完成', totalSteps, totalSteps);
    return result;
  }

  private async restoreBook(userId: string): Promise<void> {
    try {
      const localPath: string = await this.downloadCacheFile(userId + '/' + BOOK_CLOUD_NAME, 'zupu_book_restore.json');
      const content: string = this.readTextFile(localPath);
      if (content.length > 0) {
        const book: Genealogy = JSON.parse(content) as Genealogy;
        await GenealogyService.getInstance().saveBook(book);
      }
      try {
        fileIo.unlinkSync(localPath);
      } catch (err) {
        hilog.warn(0x0000, TAG, 'remove restored book failed');
      }
    } catch (err) {
      hilog.warn(0x0000, TAG, 'restore book skipped: %{public}s', JSON.stringify(err));
    }
  }

  private readTextFile(path: string): string {
    let file: fileIo.File | null = null;
    try {
      file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      const stat: fileIo.Stat = fileIo.statSync(path);
      const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
      fileIo.readSync(file.fd, buffer);
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
      return decoder.decodeToString(new Uint8Array(buffer));
    } catch (err) {
      return '';
    } finally {
      if (file !== null) {
        try {
          fileIo.closeSync(file);
        } catch (err) {
          hilog.warn(0x0000, TAG, 'close text file failed');
        }
      }
    }
  }

  // ============================ 查询与统计 ============================

  private async queryAllMembers(userId: string): Promise<CloudFamilyMember[]> {
    const zone: cloudDatabase.DatabaseZone = this.ensureZone();
    const query: cloudDatabase.DatabaseQuery<CloudFamilyMember> =
      new cloudDatabase.DatabaseQuery<CloudFamilyMember>(CloudFamilyMember);
    query.equalTo('userId', userId);
    query.equalTo('deleted', false);
    query.limit(MAX_LIST);
    return await zone.query(query);
  }

  private async queryAllMedia(userId: string): Promise<CloudFamilyMedia[]> {
    const zone: cloudDatabase.DatabaseZone = this.ensureZone();
    const query: cloudDatabase.DatabaseQuery<CloudFamilyMedia> =
      new cloudDatabase.DatabaseQuery<CloudFamilyMedia>(CloudFamilyMedia);
    query.equalTo('userId', userId);
    query.equalTo('deleted', false);
    query.limit(MAX_LIST);
    return await zone.query(query);
  }

  /** 云端占用统计 */
  async getUsage(): Promise<CloudUsage> {
    this.ensureReady();
    const userId: string = AccountService.getInstance().getUserId();
    const usage: CloudUsage = new CloudUsage();
    const members: CloudFamilyMember[] = await this.queryAllMembers(userId);
    const media: CloudFamilyMedia[] = await this.queryAllMedia(userId);
    usage.memberCount = members.length;
    usage.mediaCount = media.length;
    for (let i: number = 0; i < media.length; i++) {
      const item: CloudFamilyMedia = media[i];
      const type: string = item.type !== undefined ? item.type : 'image';
      if (type === 'video') {
        usage.videoCount++;
      } else {
        usage.imageCount++;
      }
      usage.totalBytes += item.size !== undefined ? item.size : 0;
    }
    return usage;
  }

  /** 只读预览他人分享的族谱（接收方需已登录） */
  async loadSharedMembers(ownerUserId: string): Promise<Person[]> {
    this.ensureReady();
    const members: CloudFamilyMember[] = await this.queryAllMembers(ownerUserId);
    const persons: Person[] = [];
    for (let i: number = 0; i < members.length; i++) {
      persons.push(cloudMemberToPerson(members[i]));
    }
    return persons;
  }

  // ============================ 删除云端数据 ============================

  /** 清空当前账号的全部云端数据（成员、媒体索引与文件、族谱信息） */
  async purgeCloudData(): Promise<void> {
    this.ensureReady();
    const userId: string = AccountService.getInstance().getUserId();
    const zone: cloudDatabase.DatabaseZone = this.ensureZone();
    const media: CloudFamilyMedia[] = await this.queryAllMedia(userId);
    const bucket: cloudStorage.StorageBucket = this.ensureBucket();
    for (let i: number = 0; i < media.length; i++) {
      const cloudPath: string = media[i].cloudPath !== undefined ? media[i].cloudPath as string : '';
      if (cloudPath.length > 0) {
        try {
          await bucket.deleteFile(cloudPath);
        } catch (err) {
          hilog.warn(0x0000, TAG, 'delete cloud file failed: %{public}s', cloudPath);
        }
      }
    }
    await this.deleteInBatches(media);
    const members: CloudFamilyMember[] = await this.queryAllMembers(userId);
    await this.deleteInBatches(members);
    try {
      await bucket.deleteFile(userId + '/' + BOOK_CLOUD_NAME);
    } catch (err) {
      hilog.warn(0x0000, TAG, 'delete book file skipped');
    }
    this.uriMap.clear();
    this.saveUriMap();
  }

  private async deleteInBatches(list: cloudDatabase.DatabaseObject[]): Promise<void> {
    if (list.length === 0) {
      return;
    }
    const zone: cloudDatabase.DatabaseZone = this.ensureZone();
    const batchSize: number = 20;
    for (let start: number = 0; start < list.length; start += batchSize) {
      const end: number = Math.min(start + batchSize, list.length);
      await zone.delete(list.slice(start, end));
    }
  }
}
