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

package nodomain.freeyourgadget.gadgetbridge.devices.huawei.packets;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;

import nodomain.freeyourgadget.gadgetbridge.devices.huawei.HuaweiPacket;
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.HuaweiTLV;

public class Watchface {
    public static final byte id = 0x27;

    public static class WatchfaceDeviceParams {
        public String maxVersion = "";
        public int width = 0;
        public int height = 0;
        public byte supportFileType = 1;
        public byte sort = 1;
        public String otherWatchfaceVersions = "";
    }

    public static class InstalledWatchfaceInfo {
        public String fileName = "";
        public String version = "";
        public byte type = 0;
        // bit 0 - is current
        // bit 1 - is factory preset
        // bit 2 - ???
        // bit 3 - editable
        // bit 4 - video
        // bit 5 - photo
        // bit 6 - tryout (trial version)
        // bit 7 - kaleidoskop
        public byte expandedtype = 0;

        public InstalledWatchfaceInfo(HuaweiTLV tlv) throws HuaweiPacket.MissingTagException {
            this.fileName = tlv.getString(0x03);
            this.version = tlv.getString(0x04);
            this.type = tlv.getByte(0x05);
            if (tlv.contains(0x07)) // optional
                this.expandedtype = tlv.getByte(0x07);
        }

        public boolean isCurrent() {
            return (this.type & 1) == 1;
        }
        public boolean isFactory() {
            return ((this.type  >> 1 )& 1) == 1;
        }
        public boolean isEditable() {
            return ((this.type  >> 3 )& 1) == 1;
        }
        public boolean isVideo() {
            return ((this.type  >> 4 )& 1) == 1;
        }
        public boolean isPhoto() {
            return ((this.type  >> 5 )& 1) == 1;
        }
        public boolean isTryout() {
            return ((this.type  >> 6 )& 1) == 1;
        }
        public boolean isKaleidoskop() {
            return ((this.type  >> 7 )& 1) == 1;
        }
    }

    public static class WatchfaceParams {
        public static final byte id = 0x01;
        public static class Request extends HuaweiPacket {

            public Request(ParamsProvider paramsProvider) {
                super(paramsProvider);
                this.serviceId = Watchface.id;
                this.commandId = id;

                this.tlv = new HuaweiTLV()
                        .put(0x01)
                        .put(0x02)
                        .put(0x03)
                        .put(0x04)
                        .put(0x05)
                        .put(0x0e)
                        .put(0x0f)
                        // 华为 5.39.1 请求 0x14/0x15，回包里带能力位图 0x11（决定要不要签名）。
                        // 一并问一遍，看这台 GT 5-DE1 认哪些。
                        .put(0x11)
                        .put(0x14)
                        .put(0x15);

                this.complete = true;
            }
        }

        public static class Response extends HuaweiPacket {
            public WatchfaceDeviceParams params = new WatchfaceDeviceParams();
            // 手表回包里的能力位图（tag 0x11）上游不认，先原样留个快照给上层日志
            public String rawTlv = "";
            public Response (ParamsProvider paramsProvider) {
                super(paramsProvider);
            }

            @Override
            public void parseTlv() throws ParseException {
                this.rawTlv = this.tlv.toString();
                this.params.maxVersion = this.tlv.getString(0x01);
                if (this.tlv.getBytes(0x02).length == 4)
                    this.params.width = this.tlv.getInteger(0x02);
                else
                    this.params.width = this.tlv.getShort(0x02);
                if (this.tlv.getBytes(0x03).length == 4)
                    this.params.height = this.tlv.getInteger(0x03);
                else
                    this.params.height = this.tlv.getShort(0x03);
                this.params.supportFileType = this.tlv.getByte(0x04);
                this.params.sort = this.tlv.getByte(0x05);
                if (this.tlv.contains(0x06))
                    this.params.otherWatchfaceVersions = this.tlv.getString(0x06);
            }
        }
    }

    public static class DeviceWatchInfo {
        public static final byte id = 0x02;

        public static class Request extends HuaweiPacket {
            public Request(ParamsProvider paramsProvider) {
                super(paramsProvider);
                this.serviceId = Watchface.id;
                this.commandId = id;
                this.tlv = new HuaweiTLV()
                        .put(0x01)
                        .put(0x06, (byte) 0x03); //3 -overseas non-test, 2 - test, 1 -null?
            }
        }

        public static class Response extends HuaweiPacket {

            public List<InstalledWatchfaceInfo> watchfaceInfoList;
            public Response (ParamsProvider paramsProvider) {
                super(paramsProvider);
            }

            @Override
            public void parseTlv() throws HuaweiPacket.ParseException {
                watchfaceInfoList = new ArrayList<>();
                if(this.tlv.contains(0x81)) {
                    for (HuaweiTLV subTlv : this.tlv.getObject(0x81).getObjects(0x82)) {
                        watchfaceInfoList.add(new Watchface.InstalledWatchfaceInfo(subTlv));
                    }
                }
            }
        }
    }

    public static class WatchfaceOperation {
        public static final byte id = 0x03;

        public static final byte  operationActive = 1;
        public static final byte operationDelete = 2;

        public static class Request extends HuaweiPacket {
            public Request(ParamsProvider paramsProvider,
                           String fileName, byte operation) {
                super(paramsProvider);
                this.serviceId = Watchface.id;
                this.tlv = new HuaweiTLV()
                        .put(0x01, fileName.split("_")[0])
                        .put(0x02, fileName.split("_")[1])
                        .put(0x03, operation);

                this.commandId = id;
            }
        }

        public static class Response extends HuaweiPacket {
            public Response (ParamsProvider paramsProvider) {
                super(paramsProvider);
            }
        }
    }

    public static class WatchfaceConfirm {
        public static final byte id = 0x05;

        public static class Request extends HuaweiPacket {
            public Request(ParamsProvider paramsProvider,
                           String fileName) {
                super(paramsProvider);
                this.serviceId = Watchface.id;
                this.commandId = id;
                String file = fileName.split("_")[0];
                String version = "";
                try {
                    version = fileName.split("_")[1];
                } catch (ArrayIndexOutOfBoundsException e) {

                }
                this.tlv = new HuaweiTLV()
                        .put(0x01, file)
                        .put(0x02, version)
                        .put(0x7f, 0x000186A0);
            }
        }

        public static class Response extends HuaweiPacket {
            public byte reportType = 0;
            public String fileName;
            public Response (ParamsProvider paramsProvider) {
                super(paramsProvider);
            }

            @Override
            public void parseTlv() throws HuaweiPacket.ParseException {
                String name = this.tlv.getString(0x01);
                String version = this.tlv.getString(0x02);
                if(this.tlv.contains(0x03)) {
                    this.reportType = this.tlv.getByte(0x03);
                }
                this.fileName = name + "_" + version;
            }

        }
    }

    public static class WatchfacePhotoInfo {
        public static final byte id = 0x08;

        public static final int OPTION_POSITION = 1;
        public static final int OPTION_STYLE = 2;
        public static final int OPTION_DATA = 4;

        public static class Request extends HuaweiPacket {
            public Request(ParamsProvider paramsProvider, int optionMask) {
                super(paramsProvider);
                this.serviceId = Watchface.id;
                this.commandId = id;

                this.tlv = new HuaweiTLV()
                        .put(0x01)
                        .put(0x02)
                        .put(0x03)
                        .put(0x04)
                        .put(0x0c)
                        .put(0x0d);
                if ((optionMask & OPTION_POSITION) != 0)
                    this.tlv.put(0x08);
                if ((optionMask & OPTION_STYLE) != 0)
                    this.tlv.put(0x09);
                if ((optionMask & OPTION_DATA) != 0)
                    this.tlv.put(0x0a);
                this.complete = true;
            }
        }

        public static class Response extends HuaweiPacket {
            public int maxBackgroundImages = 0;
            public boolean supportIntellectColor = false;
            public int backgroundType = 0;
            public int positionIndex = 0;
            public int styleIndex = 0;
            public int dataIndex = 0;
            public int bgImageOption = 0;
            public int portPositionIndex = 0;
            public int portraitMode = 0;
            public String rawTlv = "";

            public Response(ParamsProvider paramsProvider) {
                super(paramsProvider);
            }

            @Override
            public void parseTlv() {
                this.rawTlv = this.tlv.toString();
                this.maxBackgroundImages = this.tlv.getAsInteger(0x01, 0);
                this.supportIntellectColor = this.tlv.getAsInteger(0x02, 0) == 1;
                this.backgroundType = this.tlv.getAsInteger(0x03, 0);
                this.positionIndex = this.tlv.getAsInteger(0x08, 0);
                this.styleIndex = this.tlv.getAsInteger(0x09, 0);
                this.dataIndex = this.tlv.getAsInteger(0x0a, 0);
                this.bgImageOption = this.tlv.getAsInteger(0x0b, 0);
                this.portPositionIndex = this.tlv.getAsInteger(0x0c, 0);
                this.portraitMode = this.tlv.getAsInteger(0x0d, 0);
            }
        }
    }

    public static class WatchfaceNameInfo {
        public static final byte id = 0x06;

        public static class Request extends HuaweiPacket {
            public Request(ParamsProvider paramsProvider,
                           List<InstalledWatchfaceInfo> watchfaceList) {
                super(paramsProvider);
                this.serviceId = Watchface.id;
                this.commandId = id;

                HuaweiTLV tlvList = new HuaweiTLV();
                for (InstalledWatchfaceInfo watchface : watchfaceList) {
                    //TODO: ask name only for custom watchfaces
                    HuaweiTLV wfTlv = new HuaweiTLV().put(0x04, watchface.fileName);
                    tlvList.put(0x83, wfTlv);
                }

                this.tlv = new HuaweiTLV()
                        .put(0x01, (byte) 0x01)
                        .put(0x82, tlvList);

            }
        }

        public static class Response extends HuaweiPacket {
            public HashMap<String, String> watchFaceNames = new HashMap<String, String>();
            public Response (ParamsProvider paramsProvider) {
                super(paramsProvider);
            }

            @Override
            public void parseTlv() throws HuaweiPacket.ParseException {
                if(this.tlv.contains(0x82)) {
                    for (HuaweiTLV subTlv : this.tlv.getObject(0x82).getObjects(0x83)) {
                        watchFaceNames.put(subTlv.getString(0x04), subTlv.getString(0x05));
                    }
                }
            }
        }
    }
}
