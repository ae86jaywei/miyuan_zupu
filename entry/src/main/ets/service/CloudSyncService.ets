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
import { BookGroup, GenealogyService } from './GenealogyService';
import { GenealogyStore } from '../store/GenealogyStore';
import { AccountService } from './AccountService';
import { IntegrityService } from './IntegrityService';
import { IntegrityCode, IntegrityReport } from '../model/Integrity';
import {
  BackupResult,
  CloudFamilyMedia,
  CloudFamilyMember,
  CloudMemberPayload,
  CloudUsage,
  RestoreResult,
  cloudMemberKey,
  cloudMemberToPerson,
  personToCloudMember,
  readCloudMember
} from '../model/CloudModels';

const TAG: string = '[Genealogy][Cloud]';
const ZONE_NAME: string = 'miyuanzupu';
/** 多族谱元信息文件（新版）；book.json 为旧版单族谱文件，恢复时兼容 */
const BOOKS_CLOUD_NAME: string = 'books.json';
const BOOK_CLOUD_NAME: string = 'book.json';
const MAX_VIDEO_BYTES: number = 500 * 1024 * 1024;
const MAX_LIST: number = 1000;

/** 同步进度回调 */
export type SyncProgress = (message: string, done: number, total: number) => void;

/** 待上传媒体 */
class MediaJob {
  /** 云端成员ID（含族谱前缀） */
  memberId: string = '';
  /** 人物唯一ID（用于生成本地缓存文件名） */
  uid: string = '';
  bookKey: number = 0;
  uri: string = '';
  kind: string = 'photo';
  index: number = 0;
  isVideo: boolean = false;
}

/** 备份时按族谱收集的人物 */
class BookPeople {
  bookKey: number = 0;
  bookTitle: string = '';
  people: Person[] = [];
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
    const svc: GenealogyService = GenealogyService.getInstance();
    const books: Genealogy[] = svc.getBooks();
    if (books.length === 0) {
      throw new Error('当前没有族谱可备份，请先创建族谱');
    }
    const result: BackupResult = new BackupResult();

    // 0. 按族谱读取全部人物（不受当前打开族谱影响），确保多族谱完整备份
    const groups: BookPeople[] = [];
    for (let b: number = 0; b < books.length; b++) {
      const group: BookPeople = new BookPeople();
      group.bookKey = books[b].key;
      group.bookTitle = books[b].title;
      group.people = await svc.getPeopleOf(books[b].key);
      groups.push(group);
    }

    // 1. 成员结构化数据（带族谱前缀，恢复时可准确归位）
    const docs: CloudFamilyMember[] = [];
    for (let g: number = 0; g < groups.length; g++) {
      const group: BookPeople = groups[g];
      for (let i: number = 0; i < group.people.length; i++) {
        docs.push(personToCloudMember(group.people[i], userId, group.bookKey, group.bookTitle));
      }
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

    const jobs: MediaJob[] = [];
    for (let g: number = 0; g < groups.length; g++) {
      this.collectMediaJobs(groups[g].people, groups[g].bookKey, jobs);
    }
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
      const pathId: string = job.bookKey > 0
        ? 'b' + job.bookKey.toString() + '_' + job.uid
        : job.uid;
      const cloudPath: string = userId + '/' + pathId + '/' + prepared.relName;
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

    // 3. 族谱元信息（全部族谱：谱名、字派、谱序等）
    progress('正在上传族谱信息', docs.length, docs.length + 1);
    await this.backupBooks(userId);
    this.saveUriMap();
    progress('备份完成', docs.length + 1, docs.length + 1);
    return result;
  }

  private collectMediaJobs(people: Person[], bookKey: number, jobs: MediaJob[]): void {
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
      const photos: string[] = this.splitUris(person.photos);
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
        job.isVideo = this.isVideoUri(uri);
        jobs.push(job);
      }
      const videos: string[] = this.splitUris(person.videos);
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
    // 缓存文件名中不能使用 #（云端成员ID分隔符），改用族谱前缀区隔
    const fileId: string = job.bookKey > 0
      ? 'b' + job.bookKey.toString() + '_' + job.uid
      : job.uid;
    const base: string = fileId + '_' + prefix + '_' + job.index + '_' + stamp;
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

  /** 备份全部族谱元信息为 JSON 文件（多族谱） */
  private async backupBooks(userId: string): Promise<void> {
    const context: common.UIAbilityContext | null = AccountService.getInstance().getContext();
    if (context === null) {
      return;
    }
    const books: Genealogy[] = GenealogyService.getInstance().getBooks();
    const relName: string = 'zupu_books.json';
    const path: string = context.cacheDir + '/' + relName;
    try {
      const file: fileIo.File = fileIo.openSync(path,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, JSON.stringify(books));
      fileIo.closeSync(file);
      await this.uploadCacheFile(relName, userId + '/' + BOOKS_CLOUD_NAME);
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      hilog.warn(0x0000, TAG, 'backup books failed: %{public}s', be.message);
    } finally {
      try {
        fileIo.unlinkSync(path);
      } catch (err) {
        hilog.warn(0x0000, TAG, 'remove books cache failed');
      }
    }
  }

  // ============================ 换机恢复 ============================

  /** 从云端恢复族谱：按族谱分组全量恢复，图片按需下载，视频仅恢复引用 */
  async restoreAll(progress: SyncProgress, force: boolean = false): Promise<RestoreResult> {
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

    // 解析成员所属族谱，避免多族谱恢复时混成一部
    const payloads: CloudMemberPayload[] = [];
    const persons: Person[] = [];
    for (let i: number = 0; i < members.length; i++) {
      payloads.push(readCloudMember(members[i]));
      persons.push(cloudMemberToPerson(members[i]));
    }

    // 读取族谱元信息（新版 books.json；旧版只有 book.json）
    const books: Genealogy[] = await this.downloadBooks(userId);
    if (books.length === 0) {
      const legacy: Genealogy | null = await this.downloadLegacyBook(userId);
      if (legacy !== null) {
        books.push(legacy);
      }
    }

    // 按云端族谱ID分组；旧版数据（无前缀）归入唯一族谱
    const groups: BookGroup[] = [];
    const groupIndex: Map<number, number> = new Map<number, number>();
    for (let b: number = 0; b < books.length; b++) {
      const group: BookGroup = new BookGroup();
      group.book = books[b];
      groupIndex.set(books[b].key, groups.length);
      groups.push(group);
    }
    const effectiveKeys: number[] = [];
    for (let i: number = 0; i < members.length; i++) {
      const payload: CloudMemberPayload = payloads[i];
      let bookKey: number = payload.bookKey !== undefined ? payload.bookKey : 0;
      if (bookKey <= 0 && books.length === 1) {
        bookKey = books[0].key;
      }
      effectiveKeys.push(bookKey);
    }
    // 先归位新版记录（带族谱前缀），再补充旧版记录；
    // 同一族谱内按唯一ID去重，避免新旧备份同时存在时恢复出重复人物
    const seenByBook: Map<number, Set<string>> = new Map<number, Set<string>>();
    const duplicateReport: IntegrityReport = new IntegrityReport();
    for (let pass: number = 0; pass < 2; pass++) {
      for (let i: number = 0; i < members.length; i++) {
        const payload: CloudMemberPayload = payloads[i];
        const rawKey: number = payload.bookKey !== undefined ? payload.bookKey : 0;
        const isLegacy: boolean = rawKey <= 0;
        if ((pass === 0 && isLegacy) || (pass === 1 && !isLegacy)) {
          continue;
        }
        const bookKey: number = effectiveKeys[i];
        let idx: number | undefined = groupIndex.get(bookKey);
        if (idx === undefined) {
          // 云端缺少元信息的族谱：补建一部，避免人物丢失
          const group: BookGroup = new BookGroup();
          const rawTitle: string | undefined = payload.bookTitle;
          group.book.title = rawTitle !== undefined && rawTitle.length > 0 ? rawTitle : '我的族谱';
          idx = groups.length;
          groups.push(group);
          groupIndex.set(bookKey, idx);
        }
        let seen: Set<string> | undefined = seenByBook.get(bookKey);
        if (seen === undefined) {
          seen = new Set<string>();
          seenByBook.set(bookKey, seen);
        }
        const uid: string = persons[i].uid.trim().toUpperCase();
        if (seen.has(uid)) {
          // 第二遍补充旧版记录时，撞到新版同编号属于正常兼容去重，不报错
          if (pass === 0) {
            duplicateReport.add(IntegrityCode.UID_DUPLICATE, 'error', uid, persons[i].name,
              '云端同一部族谱内该编号出现多次，恢复后会出现人物重叠');
          }
          continue;
        }
        seen.add(uid);
        groups[idx].people.push(persons[i]);
      }
    }

    // 全量覆盖前按「每部族谱」分别体检：
    //  - 多部族谱都从 F001 开始编号，混在一起会被误判成重复ID；
    //  - 与本机同编号身份、已删除编号复用只针对当前打开的族谱。
    const svc: GenealogyService = GenealogyService.getInstance();
    const local: Person[] = svc.getPeople();
    const retired: Map<string, string> = svc.getRetiredMap();
    const currentTitle: string = svc.getBook().title;
    const report: IntegrityReport = new IntegrityReport();
    let currentGroup: BookGroup | null = null;
    for (let i: number = 0; i < groups.length; i++) {
      const group: BookGroup = groups[i];
      report.merge(IntegrityService.check(group.people, '云端《' + group.book.title + '》'));
      if (group.book.title === currentTitle) {
        currentGroup = group;
      }
    }
    if (currentGroup === null && groups.length > 0) {
      currentGroup = groups[0];
    }
    if (currentGroup !== null) {
      report.merge(IntegrityService.compare(local, currentGroup.people, '本机', '云端'));
      report.merge(IntegrityService.reused(currentGroup.people, retired));
      report.merge(IntegrityService.reusedReferences(currentGroup.people, retired));
    }
    report.merge(duplicateReport);
    if (report.hasError() && !force) {
      throw new Error('INTEGRITY:' + report.summary() + '\n' + report.detail(6));
    }

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

    for (let i: number = 0; i < persons.length; i++) {
      const person: Person = persons[i];
      let items: CloudFamilyMedia[] | undefined =
        mediaByMember.get(cloudMemberKey(effectiveKeys[i], person.uid));
      if (items === undefined) {
        // 兼容旧版：媒体记录的 memberId 即人物唯一ID
        items = mediaByMember.get(person.uid);
      }
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
          if (this.isAvatarFile(fileName, person.uid)) {
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
      done++;
      progress('正在恢复族谱成员', done, totalSteps);
    }

    const restored: number = await GenealogyService.getInstance().restoreFromCloud(groups);
    GenealogyStore.notifyChanged();
    result.memberCount = restored;
    progress('恢复完成', totalSteps, totalSteps);
    return result;
  }

  /** 判断媒体文件是否为某人的头像（兼容新旧命名） */
  private isAvatarFile(fileName: string, uid: string): boolean {
    if (fileName.startsWith(uid + '_avatar_')) {
      return true;
    }
    return fileName.indexOf('_avatar_') >= 0;
  }

  /** 下载云端全部族谱元信息 */
  private async downloadBooks(userId: string): Promise<Genealogy[]> {
    const content: string = await this.downloadTextOrEmpty(
      userId + '/' + BOOKS_CLOUD_NAME, 'zupu_books_restore.json');
    if (content.length === 0) {
      return [];
    }
    try {
      return JSON.parse(content) as Genealogy[];
    } catch (err) {
      return [];
    }
  }

  /** 下载旧版单族谱元信息（兼容历史备份） */
  private async downloadLegacyBook(userId: string): Promise<Genealogy | null> {
    const content: string = await this.downloadTextOrEmpty(
      userId + '/' + BOOK_CLOUD_NAME, 'zupu_book_restore.json');
    if (content.length === 0) {
      return null;
    }
    try {
      return JSON.parse(content) as Genealogy;
    } catch (err) {
      return null;
    }
  }

  /** 下载文本文件，失败或不存在时返回空字符串 */
  private async downloadTextOrEmpty(cloudPath: string, relName: string): Promise<string> {
    try {
      const localPath: string = await this.downloadCacheFile(cloudPath, relName);
      const content: string = this.readTextFile(localPath);
      try {
        fileIo.unlinkSync(localPath);
      } catch (err) {
        hilog.warn(0x0000, TAG, 'remove restored text failed');
      }
      return content;
    } catch (err) {
      return '';
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

  /** 统计指定族谱在云端已备份的成员数（分享前检测是否已备份） */
  async countBookMembers(ownerUserId: string, bookKey: number): Promise<number> {
    this.ensureReady();
    const members: CloudFamilyMember[] = await this.queryAllMembers(ownerUserId);
    let count: number = 0;
    for (let i: number = 0; i < members.length; i++) {
      const payload: CloudMemberPayload = readCloudMember(members[i]);
      const payloadKey: number = payload.bookKey !== undefined ? payload.bookKey : 0;
      if (payloadKey === bookKey && payload.person !== undefined && payload.person !== null) {
        count++;
      }
    }
    return count;
  }

  /**
   * 读取他人分享的族谱（只读）。
   * bookKey > 0 时只返回该族谱的成员，避免把分享者的其它族谱一并展示；
   * bookKey = 0 兼容旧版邀请码，返回全部成员。
   */
  async loadSharedMembers(ownerUserId: string, bookKey: number = 0): Promise<Person[]> {
    this.ensureReady();
    const members: CloudFamilyMember[] = await this.queryAllMembers(ownerUserId);
    const persons: Person[] = [];
    const seen: Set<string> = new Set<string>();
    for (let i: number = 0; i < members.length; i++) {
      const payload: CloudMemberPayload = readCloudMember(members[i]);
      const payloadKey: number = payload.bookKey !== undefined ? payload.bookKey : 0;
      if (bookKey > 0 && payloadKey !== bookKey) {
        continue;
      }
      const person: Person = cloudMemberToPerson(members[i]);
      if (person.uid.length === 0 || seen.has(person.uid)) {
        continue;
      }
      seen.add(person.uid);
      persons.push(person);
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
      await bucket.deleteFile(userId + '/' + BOOKS_CLOUD_NAME);
    } catch (err) {
      hilog.warn(0x0000, TAG, 'delete books file skipped');
    }
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
