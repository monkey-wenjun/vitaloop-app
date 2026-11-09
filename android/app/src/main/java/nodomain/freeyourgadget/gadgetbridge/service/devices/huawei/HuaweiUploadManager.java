/*  Copyright (C) 2024 Vitalii Tomin

    This file is part of Gadgetbridge.

    Gadgetbridge is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as published
    by the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    Gadgetbridge is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with this program.  If not, see <https://www.gnu.org/licenses/>. */

package nodomain.freeyourgadget.gadgetbridge.service.devices.huawei;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;

import nodomain.freeyourgadget.gadgetbridge.devices.huawei.packets.FileUpload;
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.packets.FileUpload.FileUploadParams;
import nodomain.freeyourgadget.gadgetbridge.util.GB;

/**
 * 华为手表文件上传管理器（移植自 Gadgetbridge，精简掉设备忙碌状态 UI）
 */
public class HuaweiUploadManager {
    private static final Logger LOG = LoggerFactory.getLogger(HuaweiUploadManager.class);

    public interface FileUploadCallback {
        void onUploadStart();
        void onUploadProgress(int progress);
        void onUploadComplete();
        void onError(int code);
    }

    public static class FileUploadInfo {
        private byte[] fileBin;
        private byte[] fileSHA256;
        private byte fileType = 1;
        private int fileSize = 0;
        private byte fileId = 0;

        private String fileName = "";

        private String srcPackage = null;
        private String dstPackage = null;
        private String srcFingerprint = null;
        private String dstFingerprint = null;

        private int currentUploadPosition = 0;
        private int uploadChunkSize = 0;

        /** 占用这个文件的是谁（music / calendar / watchface / app），见 HuaweiUploadManager#claimFileUploadSlot */
        private String owner = null;

        private FileUploadCallback fileUploadCallback = null;

        private FileUploadParams fileUploadParams = null;

        public String getOwner() {
            return owner;
        }

        public void setOwner(String owner) {
            this.owner = owner;
        }

        public FileUploadCallback getFileUploadCallback() {
            return fileUploadCallback;
        }

        public void setFileUploadCallback(FileUploadCallback fileUploadCallback) {
            this.fileUploadCallback = fileUploadCallback;
        }

        public void setFileUploadParams(FileUploadParams params) {
            this.fileUploadParams = params;
        }

        public int getUnitSize() {
            return fileUploadParams.unit_size;
        }

        public boolean getEncrypt() {
            return fileUploadParams.no_encrypt == 0;
        }

        public void setBytes(byte[] uploadArray) {
            this.fileSize = uploadArray.length;
            this.fileBin = uploadArray;

            try {
                MessageDigest m = MessageDigest.getInstance("SHA256");
                m.update(fileBin, 0, fileBin.length);
                fileSHA256 = m.digest();
            } catch (NoSuchAlgorithmException e) {
                LOG.error("Digest algorithm not found.", e);
                return;
            }

            currentUploadPosition = 0;
            uploadChunkSize = 0;

            LOG.info("File ready for upload, SHA256: " + GB.hexdump(fileSHA256) + " fileName: " + fileName);
        }

        public int getFileSize() {
            return fileSize;
        }

        public String getFileName() {
            return this.fileName;
        }

        public void setFileName(String fileName) {
            this.fileName = fileName;
        }

        public byte getFileType() {
            return this.fileType;
        }

        public void setFileType(byte fileType) {
            this.fileType = fileType;
        }

        public byte getFileId() {
            return fileId;
        }

        public void setFileId(byte fileId) {
            this.fileId = fileId;
        }

        public String getSrcPackage() { return srcPackage; }

        public void setSrcPackage(String srcPackage) { this.srcPackage = srcPackage; }

        public String getDstPackage() { return dstPackage; }

        public void setDstPackage(String dstPackage) { this.dstPackage = dstPackage; }

        public String getSrcFingerprint() { return srcFingerprint; }

        public void setSrcFingerprint(String srcFingerprint) { this.srcFingerprint = srcFingerprint; }

        public String getDstFingerprint() { return dstFingerprint;}

        public void setDstFingerprint(String dstFingerprint) { this.dstFingerprint = dstFingerprint;}

        public byte[] getFileSHA256() {
            return fileSHA256;
        }

        public void setUploadChunkSize(int chunkSize) {
            uploadChunkSize = chunkSize;
        }

        public void setCurrentUploadPosition (int pos) {
            currentUploadPosition = pos;
        }

        public int getCurrentUploadPosition() {
            return currentUploadPosition;
        }

        public byte[] getCurrentChunk() {
            byte[] ret = new byte[uploadChunkSize];
            System.arraycopy(fileBin, currentUploadPosition, ret, 0, uploadChunkSize);
            return ret;
        }
    }

    private final IHuaweiSupport support;

    FileUploadInfo fileUploadInfo = null;

    /** 抢不到文件槽、在等业务的一方，槽主下一轮开传前会看一眼并主动让出一次 */
    private String pendingSlotWaiter = null;

    public HuaweiUploadManager(IHuaweiSupport support) {
        this.support = support;
    }

    public FileUploadInfo getFileUploadInfo() {
        return fileUploadInfo;
    }

    public void setFileUploadInfo(FileUploadInfo fileUploadInfo) {
        this.fileUploadInfo = fileUploadInfo;
    }

    public synchronized boolean isFileUploadSlotFree(String owner) {
        return fileUploadInfo == null || owner.equals(fileUploadInfo.getOwner());
    }

    public synchronized String getFileUploadOwner() {
        return fileUploadInfo == null ? null : fileUploadInfo.getOwner();
    }

    /**
     * 挂上待上传文件，前提是槽空闲或本来就属于同一个业务。
     * 协议层只有一份 fileUploadInfo，而分片是手表逐块索要、手机逐块应答的：两个业务交错
     * 占用会让分片偏移对不上，双方都传不成（2026-10-29 实测：连接就绪那一秒日历抢走了
     * 音乐的文件槽，第一首传到一半手表就不再要数据）。抢不到时把来者登记成等待方，
     * 由调用方决定稍后重试。
     *
     * @return true 表示文件已挂上；false 表示槽被其他业务占用，未做任何改动
     */
    public synchronized boolean claimFileUploadSlot(FileUploadInfo info) {
        String owner = info.getOwner();
        if (owner == null) {
            throw new IllegalArgumentException("FileUploadInfo.owner must be set before claiming the slot");
        }
        if (!isFileUploadSlotFree(owner)) {
            pendingSlotWaiter = owner;
            return false;
        }
        this.fileUploadInfo = info;
        return true;
    }

    /** 取走在等的业务（一次性的：让位一轮，避免两个业务互相让来让去）。 */
    public synchronized String takePendingSlotWaiter() {
        String waiter = pendingSlotWaiter;
        pendingSlotWaiter = null;
        return waiter;
    }
}
