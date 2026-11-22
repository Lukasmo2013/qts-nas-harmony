import fs from '@ohos.file.fs';
import { DownloadResult, OpResult } from '../model/Models';
import { QnapApi } from './QnapApi';

/** 传输任务（上传或下载）的可见状态。 */
export interface TransferTask {
  id: string;
  /** 'upload' | 'download' */
  kind: string;
  name: string;
  /** 上传=远端目录；下载=本机保存 uri */
  target: string;
  size: number;
  done: number;
  /** queued | running | success | failed | canceled */
  state: string;
  status: number;
  startedAt: number;
  finishedAt: number;
}

interface UploadJob {
  taskId: string;
  destPath: string;
  name: string;
  /** 内存数据（新建 txt 等小文件）；为空时改用 uri 惰性读取 */
  data: Uint8Array;
  /** 文件选择器返回的 uri；运行时才读字节，避免多选大文件时一次性占满内存 */
  uri: string;
}

interface DownloadJob {
  taskId: string;
  remotePath: string;
  saveUri: string;
}

/** 任务状态常量（避免各页面写字符串字面量写错）。 */
export class TransferState {
  static readonly QUEUED: string = 'queued';
  static readonly RUNNING: string = 'running';
  static readonly SUCCESS: string = 'success';
  static readonly FAILED: string = 'failed';
  static readonly CANCELED: string = 'canceled';
}

/**
 * 后台上传 / 下载管理器。
 *
 * 为什么要有它：文件页原来的做法是「点一下 → 等 → 弹 toast」，期间不能离开页面，
 * 大文件还会把界面卡在 busy 态，失败后也看不到是哪一个文件、错在什么地方。
 *
 * 这里改成队列：任务入队后立刻返回，由 pump() 串行执行（QTS 对并发上传不友好），
 * 进度/结果写进静态任务表并通过 AppStorage 的 transferTick 通知界面刷新。
 * 因此切到别的页、甚至锁屏再回来，任务都还在跑，列表也能看到结果。
 */
export class TransferManager {
  private static tasks: TransferTask[] = [];
  private static uploadJobs: UploadJob[] = [];
  private static downloadJobs: DownloadJob[] = [];
  private static running: boolean = false;
  private static seq: number = 0;

  /** 当前全部任务（新的在前）。 */
  static list(): TransferTask[] {
    const out: TransferTask[] = [];
    for (let i = TransferManager.tasks.length - 1; i >= 0; i--) {
      out.push(TransferManager.tasks[i]);
    }
    return out;
  }

  static runningCount(): number {
    let n: number = 0;
    for (const t of TransferManager.tasks) {
      if (t.state === TransferState.RUNNING || t.state === TransferState.QUEUED) {
        n++;
      }
    }
    return n;
  }

  static activeProgress(): number {
    for (const t of TransferManager.tasks) {
      if (t.state === TransferState.RUNNING && t.size > 0) {
        return Math.min(100, Math.floor(t.done * 100 / t.size));
      }
    }
    return 0;
  }

  static failedCount(): number {
    let n: number = 0;
    for (const t of TransferManager.tasks) {
      if (t.state === TransferState.FAILED) {
        n++;
      }
    }
    return n;
  }

  /** 上传入队（数据已在内存里，调用方负责先读好文件字节）。 */
  static enqueueUpload(destPath: string, name: string, data: Uint8Array): string {
    TransferManager.seq++;
    const id: string = 'u' + String(Date.now()) + '_' + String(TransferManager.seq);
    const task: TransferTask = {
      id: id,
      kind: 'upload',
      name: name,
      target: destPath,
      size: data.byteLength,
      done: 0,
      state: TransferState.QUEUED,
      status: 0,
      startedAt: 0,
      finishedAt: 0
    };
    TransferManager.tasks.push(task);
    const job: UploadJob = { taskId: id, destPath: destPath, name: name, data: data, uri: '' };
    TransferManager.uploadJobs.push(job);
    TransferManager.notify();
    TransferManager.pump();
    return id;
  }

  /**
   * 上传入队（按 uri 惰性读取）。
   * 多选文件时只有轮到它执行才读字节，避免一次性把所有文件读进内存。
   */
  static enqueueUploadFromUri(destPath: string, name: string, uri: string, sizeHint: number): string {
    TransferManager.seq++;
    const id: string = 'u' + String(Date.now()) + '_' + String(TransferManager.seq);
    const task: TransferTask = {
      id: id,
      kind: 'upload',
      name: name,
      target: destPath,
      size: sizeHint,
      done: 0,
      state: TransferState.QUEUED,
      status: 0,
      startedAt: 0,
      finishedAt: 0
    };
    TransferManager.tasks.push(task);
    const job: UploadJob = {
      taskId: id, destPath: destPath, name: name,
      data: new Uint8Array(0), uri: uri
    };
    TransferManager.uploadJobs.push(job);
    TransferManager.notify();
    TransferManager.pump();
    return id;
  }

  /** 下载入队（保存位置由调用方先用系统选择器确定，这里只负责取字节并落盘）。 */
  static enqueueDownload(remotePath: string, saveUri: string, name: string, sizeHint: number): string {
    TransferManager.seq++;
    const id: string = 'd' + String(Date.now()) + '_' + String(TransferManager.seq);
    const task: TransferTask = {
      id: id,
      kind: 'download',
      name: name,
      target: saveUri,
      size: sizeHint,
      done: 0,
      state: TransferState.QUEUED,
      status: 0,
      startedAt: 0,
      finishedAt: 0
    };
    TransferManager.tasks.push(task);
    const job: DownloadJob = { taskId: id, remotePath: remotePath, saveUri: saveUri };
    TransferManager.downloadJobs.push(job);
    TransferManager.notify();
    TransferManager.pump();
    return id;
  }

  /** 取消：排队中的直接取消；运行中的在当前分片结束时停止。 */
  static cancel(id: string): void {
    const task: TransferTask | null = TransferManager.find(id);
    if (task === null || task.state === TransferState.SUCCESS) {
      return;
    }
    task.state = TransferState.CANCELED;
    task.finishedAt = Date.now();
    TransferManager.notify();
  }

  /** 重试失败/取消的任务（按 id 重新入队一次）。 */
  static retry(id: string): void {
    const task: TransferTask | null = TransferManager.find(id);
    if (task === null || task.state === TransferState.RUNNING ||
      task.state === TransferState.QUEUED || task.state === TransferState.SUCCESS) {
      return;
    }
    if (task.kind === 'download') {
      // 下载的原始远端路径没有单独存，target 是保存 uri；重试需要重新选位置，交给界面处理。
      return;
    }
    const job: UploadJob | null = TransferManager.takeUploadJob(id);
    if (job === null) {
      return;
    }
    task.state = TransferState.QUEUED;
    task.done = 0;
    task.status = 0;
    task.startedAt = 0;
    task.finishedAt = 0;
    TransferManager.uploadJobs.push(job);
    TransferManager.notify();
    TransferManager.pump();
  }

  /** 清掉已结束的任务（成功 / 失败 / 取消）。 */
  static clearFinished(): void {
    const keep: TransferTask[] = [];
    for (const t of TransferManager.tasks) {
      if (t.state === TransferState.RUNNING || t.state === TransferState.QUEUED) {
        keep.push(t);
      }
    }
    TransferManager.tasks = keep;
    TransferManager.notify();
  }

  private static find(id: string): TransferTask | null {
    for (const t of TransferManager.tasks) {
      if (t.id === id) {
        return t;
      }
    }
    return null;
  }

  private static takeUploadJob(id: string): UploadJob | null {
    for (let i = 0; i < TransferManager.uploadJobs.length; i++) {
      if (TransferManager.uploadJobs[i].taskId === id) {
        const job: UploadJob = TransferManager.uploadJobs[i];
        TransferManager.uploadJobs.splice(i, 1);
        return job;
      }
    }
    return null;
  }

  /** 串行泵：同一时刻只跑一个任务，避免并发上传被设备限流/拒绝。 */
  private static async pump(): Promise<void> {
    if (TransferManager.running) {
      return;
    }
    TransferManager.running = true;
    try {
      while (true) {
        if (TransferManager.uploadJobs.length > 0) {
          const job: UploadJob = TransferManager.uploadJobs.shift() as UploadJob;
          await TransferManager.runUpload(job);
          continue;
        }
        if (TransferManager.downloadJobs.length > 0) {
          const job: DownloadJob = TransferManager.downloadJobs.shift() as DownloadJob;
          await TransferManager.runDownload(job);
          continue;
        }
        break;
      }
    } finally {
      TransferManager.running = false;
    }
  }

  /** 读本地文件字节（uri 形态），大文件按已读偏移循环补齐。 */
  private static readUri(uri: string): Uint8Array {
    const file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
    try {
      const fd: number = file.fd;
      const size: number = fs.statSync(fd).size;
      const buf: ArrayBuffer = new ArrayBuffer(size);
      if (size > 0) {
        let read: number = 0;
        while (read < size) {
          const n: number = fs.readSync(fd, buf, { offset: read, length: size - read });
          if (n <= 0) {
            break;
          }
          read += n;
        }
      }
      return new Uint8Array(buf);
    } finally {
      fs.closeSync(file);
    }
  }

  private static async runUpload(job: UploadJob): Promise<void> {
    const task: TransferTask | null = TransferManager.find(job.taskId);
    if (task === null) {
      return;
    }
    if (task.state === TransferState.CANCELED) {
      return;
    }
    task.state = TransferState.RUNNING;
    task.startedAt = Date.now();
    TransferManager.notify();

    let bytes: Uint8Array = job.data;
    if (job.uri.length > 0) {
      try {
        bytes = TransferManager.readUri(job.uri);
      } catch (e) {
        task.state = TransferState.FAILED;
        task.status = -5;   // 本地文件读不出来（权限/已被删除）
        task.finishedAt = Date.now();
        TransferManager.notify();
        return;
      }
    }
    task.size = bytes.byteLength;
    task.done = 0;
    TransferManager.notify();
    try {
      const result: OpResult = await QnapApi.uploadFile(job.destPath, job.name, bytes, true,
        (done: number, total: number) => {
          task.done = done;
          task.size = total;
          TransferManager.notify();
        },
        () => task.state === TransferState.CANCELED);
      if (task.state === TransferState.CANCELED) {
        return;
      }
      if (result.ok) {
        task.state = TransferState.SUCCESS;
        task.done = task.size;
        task.status = 1;
      } else {
        task.state = TransferState.FAILED;
        task.status = result.status;
      }
    } catch (e) {
      if (task.state !== TransferState.CANCELED) {
        task.state = TransferState.FAILED;
        task.status = -1;
      }
    } finally {
      task.finishedAt = Date.now();
      TransferManager.notify();
    }
  }

  private static async runDownload(job: DownloadJob): Promise<void> {
    const task: TransferTask | null = TransferManager.find(job.taskId);
    if (task === null) {
      return;
    }
    if (task.state === TransferState.CANCELED) {
      return;
    }
    task.state = TransferState.RUNNING;
    task.startedAt = Date.now();
    task.done = 0;
    TransferManager.notify();
    try {
      const result: DownloadResult = await QnapApi.downloadFile(job.remotePath);
      if (task.state === TransferState.CANCELED) {
        return;
      }
      if (!result.ok || result.data === null) {
        task.state = TransferState.FAILED;
        task.status = result.status;
        return;
      }
      const bytes: ArrayBuffer = result.data as ArrayBuffer;
      const file = fs.openSync(job.saveUri, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE);
      try {
        fs.writeSync(file.fd, bytes);
      } finally {
        fs.closeSync(file);
      }
      task.size = bytes.byteLength;
      task.done = bytes.byteLength;
      task.state = TransferState.SUCCESS;
      task.status = 200;
    } catch (e) {
      if (task.state !== TransferState.CANCELED) {
        task.state = TransferState.FAILED;
        task.status = -1;
      }
    } finally {
      task.finishedAt = Date.now();
      TransferManager.notify();
    }
  }

  /** 通过 AppStorage 的时间戳让界面刷新（@StorageLink('transferTick')）。 */
  private static notify(): void {
    AppStorage.setOrCreate<number>('transferTick', Date.now());
  }
}
