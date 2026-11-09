package nodomain.freeyourgadget.gadgetbridge.devices.huawei.packets;

import nodomain.freeyourgadget.gadgetbridge.devices.huawei.HuaweiPacket;
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.HuaweiTLV;

public class Ephemeris {
    public static final int id = 0x1f;

    public static class OperatorData {
        public static final int id = 0x01;

        public static class OperatorIncomingRequest extends HuaweiPacket {
            public byte operationInfo;
            public int operationTime;

            public OperatorIncomingRequest(ParamsProvider paramsProvider) {
                super(paramsProvider);
            }

            @Override
            public void parseTlv() throws ParseException {

                //TODO: can contain many elements.
                //List<HuaweiTLV> subContainers = container.getObjects(0x81);
                HuaweiTLV subTlv = this.tlv.getObject(0x81);

                this.operationInfo = subTlv.getByte(0x02);
                this.operationTime = subTlv.getInteger(0x03);
            }
        }

        public static class OperatorResponse extends HuaweiPacket {

            public OperatorResponse(ParamsProvider paramsProvider, int responseCode) {
                super(paramsProvider);

                this.serviceId = Ephemeris.id;
                this.commandId = id;

                this.tlv = new HuaweiTLV().put(0x7f, responseCode);

                this.complete = true;
            }
        }
    }

    public static class ParameterConsult {
        public static final byte id = 0x02;

        public static class Request extends HuaweiPacket {


            public Request(ParamsProvider paramsProvider) {
                super(paramsProvider);
                this.serviceId = Ephemeris.id;
                this.commandId = id;
                this.tlv = new HuaweiTLV().put(0x81);
            }
        }

        public static class Response extends HuaweiPacket {
            public int consultDeviceTime;
            public byte downloadVersion;
            public String downloadTag;
            /** 是否带协商容器 0x81（带 = 手表愿意继续，数据在 0x04/0x05/0x06 里） */
            public boolean hasConsultInfo;
            /** 不带 0x81 时手表只回状态码 tag 0x7f（100000=OK；GT5 主动协商被婉拒时实测回 118001） */
            public int responseCode;

            public Response (ParamsProvider paramsProvider) {
                super(paramsProvider);
            }

            @Override
            public void parseTlv() throws HuaweiPacket.ParseException {
                // 手表可能只回状态码不带协商容器：主动推送时手表觉得数据够新就是这种
                // 极简应答，严格解析会把响应当异常丢掉，看不到手表的真实态度。
                if (this.tlv.contains(0x81)) {
                    HuaweiTLV subTlv = this.tlv.getObject(0x81);
                    this.consultDeviceTime = subTlv.getByte(0x04) * 1000;
                    this.downloadVersion = subTlv.getByte(0x05);
                    this.downloadTag = subTlv.getString(0x06);
                    this.hasConsultInfo = true;
                } else if (this.tlv.contains(0x7f)) {
                    this.responseCode = this.tlv.getInteger(0x7f);
                }
            }

        }
    }

    public static class FileStatus {
        public static final byte id = 0x03;

        public static class Request extends HuaweiPacket {


            public Request(ParamsProvider paramsProvider, byte status) {
                super(paramsProvider);
                this.serviceId = Ephemeris.id;
                this.commandId = id;
                this.tlv = new HuaweiTLV().put(0x1, status);
            }
        }

        public static class Response extends HuaweiPacket {
            public int responseCode;

            public Response (ParamsProvider paramsProvider) {
                super(paramsProvider);
            }

            @Override
            public void parseTlv() throws HuaweiPacket.ParseException {
                this.responseCode = this.tlv.getInteger(0x7f);
            }

        }
    }

}
