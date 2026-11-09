/*  Copyright (C) 2024 Damien Gaignon, Martin.JM

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
package nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests;

import android.content.Context;
import android.os.Handler;
import android.os.Looper;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.io.IOException;
import java.nio.ByteBuffer;
import java.util.List;

import nodomain.freeyourgadget.gadgetbridge.devices.huawei.HuaweiCrypto;
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.HuaweiPacket;
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.HuaweiTLV;
import nodomain.freeyourgadget.gadgetbridge.impl.GBDevice;
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.IHuaweiSupport;
import nodomain.freeyourgadget.gadgetbridge.util.GB;

import com.awen.running.utils.FileLogger;

// Based on nodomain.freeyourgadget.gadgetbridge.service.devices.lefun.requests.Request

/**
 * Add capacity to :
 *     - chain requests;
 *     - use data from a past request;
 *     - call a function after last request.
 */

public class Request {
    private static final Logger LOG = LoggerFactory.getLogger(Request.class);

    public static class RequestCreationException extends Exception {
        public RequestCreationException(String message) {
            super(message);
        }

        public RequestCreationException(HuaweiPacket.CryptoException e) {
            super(e);
        }

        public RequestCreationException(String message, Exception e) {
            super(message, e);
        }
    }

    public static class ResponseParseException extends Exception {
        public ResponseParseException(String message) {
            super(message);
        }

        public ResponseParseException(Exception e) {
            super(e);
        }

        public ResponseParseException(String message, Exception e) {
            super(message, e);
        }
    }

    public static class ResponseTypeMismatchException extends ResponseParseException {
        public ResponseTypeMismatchException(HuaweiPacket a, Class<?> b) {
            super("Response type mismatch, packet is of type " + a.getClass() + " but expected " + b);
        }

        public ResponseTypeMismatchException(HuaweiPacket a, Class<?> b, Class<?> c) {
            super("Response type mismatch, packet is of type " + a.getClass() + " but expected " + b + " or " + c);
        }
    }

    public static class WorkoutParseException extends ResponseParseException {
        public WorkoutParseException(String message) {
            super(message);
        }
    }

    protected boolean requestFinished = false;
    protected byte serviceId;
    protected byte commandId;
    protected HuaweiPacket receivedPacket = null;
    protected IHuaweiSupport supportProvider;
    protected HuaweiPacket.ParamsProvider paramsProvider;
    // Be able to autostart a request after this one
    protected Request nextRequest = null;
    protected boolean isSelfQueue = false;
    // Callback function to start after the request
    protected RequestCallback finalizeReq = null;
    // Stop chaining requests and clean support.inProgressRequests from these requests
    protected boolean stopChain = false;
    protected HuaweiCrypto huaweiCrypto = null;
    protected boolean addToResponse = true;

    private final Handler handler;
    private final Runnable timeoutRunner;
    private Integer timeout = null;

    public static class RequestCallback {
        protected IHuaweiSupport support = null;
        public RequestCallback() {}
        public RequestCallback(IHuaweiSupport supportProvider) {
            support = supportProvider;
        }
        public void call() {}
        public void call(Request request) {
            call(); // To keep everything working as it was as well
        }
        public void handleException(ResponseParseException e) {
            LOG.error("Callback request exception", e);
        }
        public void timeout(Request request) {
            request.handleNext();
        }
    }

    private Runnable getTimeoutRunnable() {
        return () -> {
            LOG.debug("Timeout on Service {} command {}", Integer.toHexString(this.serviceId & 0xff), Integer.toHexString(this.commandId & 0xff));
            FileLogger.INSTANCE.w("Request", "请求超时未应答: " + this.getClass().getSimpleName()
                    + " svc=0x" + Integer.toHexString(this.serviceId & 0xff)
                    + " cmd=0x" + Integer.toHexString(this.commandId & 0xff)
                    + " → 跳过它，继续往下走");
            if (finalizeReq != null)
                finalizeReq.timeout(this);
            else
                this.handleNext();
        };
    }

    public Request(IHuaweiSupport supportProvider) {
        this.supportProvider = supportProvider;
        this.paramsProvider = supportProvider.getParamsProvider();
        this.isSelfQueue = true;
        this.handler = new Handler(Looper.getMainLooper());
        this.timeoutRunner = getTimeoutRunnable();
    }

    protected boolean requestSupported() {
        return true;
    }

    public void doPerform() throws IOException {
        if (!requestSupported()) {
            this.handleNext();
            return;
        }

        if (this.addToResponse) {
            supportProvider.addInProgressRequest(this);
        }
        try {
            for (byte[] request : createRequest()) {
                int mtu = paramsProvider.getMtu();
                if (request.length >= mtu) {
                    ByteBuffer buffer = ByteBuffer.wrap(request);
                    byte[] data;
                    while (buffer.hasRemaining()) {
                        int delta = Math.min(mtu, buffer.remaining());
                        data = new byte[delta];
                        buffer.get(data, 0, delta);
                        supportProvider.write(data);
                    }
                } else {
                    supportProvider.write(request);
                }
            }
            supportProvider.waitMillis(paramsProvider.getInterval()); // Need to wait a little to let some requests end correctly i.e. Battery Level on reconnection to not print correctly
            if (isSelfQueue) {
                performConnected();
            }
        } catch (RequestCreationException e) {
            // We cannot throw the RequestCreationException, so we throw an IOException
            throw new IOException("Request could not be created", e);
        }
    }

    protected List<byte[]> createRequest() throws RequestCreationException {
        return null;
    }

    protected void processResponse() throws ResponseParseException {}

    public void handleResponse() {
        // Stop timeout timer
        this.handler.removeCallbacks(this.timeoutRunner);

        try {
            this.receivedPacket.parseTlv();
        } catch (HuaweiPacket.ParseException e) {
            failChain("响应 TLV 解析失败", new ResponseParseException("Parse TLV exception", e));
            return;
        }
        try {
            this.processResponse();
        } catch (ResponseParseException e) {
            failChain("响应处理失败", e);
            return;
        }
        handleNext();
    }

    /**
     * 链上任何一次响应处理失败都走不下去了 —— 下一个请求是在 processResponse 里才建出来的
     * （运动链的下一页、下一个运动都在那之后），所以此时 handleNext() 无事可推进。
     * 上游这里只写 slf4j，文件日志一行都没有，表现就是同步“悄无声息地不再动了”：
     * 2026-10-30 拉全量运动记录时日志里成串出现 MissingTagException: Missing tag: 81，
     * 链一死，后面排队的运动一个都不会再拉，事后从文件日志完全看不出为什么。
     */
    private void failChain(String what, ResponseParseException e) {
        LOG.error("{}: {} ({}) packet={} tlv={}", what, this.getClass().getSimpleName(), e.getMessage(),
                describeReceivedPacket(), describeReceivedTlv(), e);
        if (finalizeReq != null) {
            FileLogger.INSTANCE.e("Request", what + "，整条链中止: " + this.getClass().getSimpleName()
                    + " " + e.getMessage() + " " + describeReceivedPacket() + " tlv=" + describeReceivedTlv(), e);
            finalizeReq.handleException(e);
        } else {
            // 没有收尾回调可通知时，至少要自己往下走：超时定时器已经在第一行被取消，
            // 不推进就等于整条链就地死亡，链尾的回调（本项目里它是启动定时同步的唯一入口）再也不会执行
            FileLogger.INSTANCE.e("Request", what + "（无收尾回调，继续推进链）: "
                    + this.getClass().getSimpleName() + " " + e.getMessage()
                    + " " + describeReceivedPacket() + " tlv=" + describeReceivedTlv(), e);
            handleNext();
        }
    }

    private String describeReceivedPacket() {
        if (receivedPacket == null)
            return "packet=null";
        return "svc=0x" + Integer.toHexString(receivedPacket.serviceId & 0xff)
                + " cmd=0x" + Integer.toHexString(receivedPacket.commandId & 0xff)
                + " expects svc=0x" + Integer.toHexString(serviceId & 0xff)
                + " cmd=0x" + Integer.toHexString(commandId & 0xff);
    }

    /** 原始 TLV：并发链互相抢响应时，只有字节能证明这个包本来是谁的；探针类也要靠它留证 */
    protected String describeReceivedTlv() {
        HuaweiTLV tlv = receivedPacket == null ? null : receivedPacket.getTlv();
        if (tlv == null)
            return "";
        try {
            byte[] raw = tlv.serialize();
            StringBuilder sb = new StringBuilder(raw.length * 2);
            for (int i = 0; i < raw.length && i < 192; i++) {
                sb.append(String.format("%02x", raw[i]));
            }
            if (raw.length > 192)
                sb.append("...(").append(raw.length).append(")");
            return sb.toString();
        } catch (Exception e) {
            return "(serialize failed)";
        }
    }

    public void handleNext() {
        if (nextRequest != null && !stopChain) {
            try {
                nextRequest.doPerform();
            } catch (IOException e) {
                LOG.error("Next request failed", e);
                if (finalizeReq != null)
                    finalizeReq.handleException(new ResponseParseException("Next request failed", e));
                return;
            }
        }
        if (nextRequest == null || stopChain) {
            requestFinished = true;
            if (finalizeReq != null) {
                finalizeReq.call(this);
            }
        }
        nextRequest = null;
    }

    public void setSelfQueue() {
        isSelfQueue = true;
    }

    public Request nextRequest(Request req) {
        if (req != null) {
            nextRequest = req;
            nextRequest.setSelfQueue();
        }
        return this;
    }

    public void stopChain(Request req) {
        req.stopChain();
        Request next = req.nextRequest;
        if (next != null) {
            next.stopChain(next);
            supportProvider.removeInProgressRequests(next);
        }
    }

    public void stopChain() {
        stopChain = true;
    }

    /**
     * Handler for responses from the device
     * @param response The response packet
     * @return True if this request handles this response, false otherwise
     */
    public boolean handleResponse(HuaweiPacket response) {
        if (response.serviceId == serviceId && response.commandId == commandId) {
            receivedPacket = response;
            return true;
        }
        return false;
    }

    protected Context getContext() {
        return supportProvider.getContext();
    }

    protected GBDevice getDevice() {
        return supportProvider.getDevice();
    }

    public String getName() {
        Class<?> thisClass = getClass();
        while (thisClass.isAnonymousClass()) thisClass = thisClass.getSuperclass();
        return thisClass.getSimpleName();
    }

    public void setFinalizeReq(RequestCallback finalizeReq) {
        this.finalizeReq = finalizeReq;
    }

    private void performConnected() throws IOException {
        LOG.debug("Perform connected");

        // Start the timeout timer
        if (this.timeout != null)
            handler.postDelayed(this.timeoutRunner, this.timeout);
    }

    public boolean autoRemoveFromResponseHandler() {
        return true;
    }

    public void setupTimeoutUntilNext(int timeout) {
        this.timeout = timeout;
    }

    @Override
    protected void finalize() throws Throwable {
        // Stop timeout timer
        this.handler.removeCallbacks(this.timeoutRunner);

        super.finalize();
    }
}
