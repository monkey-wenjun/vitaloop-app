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

import java.util.List;

import nodomain.freeyourgadget.gadgetbridge.devices.huawei.HuaweiPacket;
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.packets.Workout;
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.IHuaweiSupport;
import com.awen.running.utils.FileLogger;

public class GetWorkoutCountRequest extends Request {
    private final int start;
    private final int end;

    public GetWorkoutCountRequest(IHuaweiSupport support, int start, int end) {
        super(support);

        this.serviceId = Workout.id;
        this.commandId = Workout.WorkoutCount.id;

        this.start = start;
        this.end = end;
    }

    @Override
    protected List<byte[]> createRequest() throws RequestCreationException {
        try {
            return new Workout.WorkoutCount.Request(paramsProvider, this.start, this.end).serialize();
        } catch (HuaweiPacket.CryptoException e) {
            throw new RequestCreationException(e);
        }
    }

    private static String describe(List<Workout.WorkoutCount.Response.WorkoutNumbers> numbers) {
        StringBuilder sb = new StringBuilder();
        for (Workout.WorkoutCount.Response.WorkoutNumbers n : numbers) {
            if (sb.length() > 0) sb.append(' ');
            sb.append('#').append(n.workoutNumber)
              .append("(data=").append(n.dataCount)
              .append(",pace=").append(n.paceCount)
              .append(",seg=").append(n.segmentsCount).append(')');
        }
        return sb.toString();
    }

    @Override
    protected void processResponse() throws ResponseParseException {
        if (!(receivedPacket instanceof Workout.WorkoutCount.Response))
            throw new ResponseTypeMismatchException(receivedPacket, Workout.WorkoutCount.Response.class);

        Workout.WorkoutCount.Response packet = (Workout.WorkoutCount.Response) receivedPacket;

        if (packet.count != packet.workoutNumbers.size())
            throw new WorkoutParseException("Packet count and workout numbers size do not match.");

        // 过滤用户已删除的运动编号：不请求汇总/轨迹，避免重新入库并上传到博客服务端
        packet.workoutNumbers.removeIf(
            n -> supportProvider.isWorkoutDeleted(n.workoutNumber)
        );

        FileLogger.INSTANCE.i("GetWorkoutCountRequest",
                "运动数量: count=" + packet.count +
                " 有效=" + packet.workoutNumbers.size() +
                " 编号=" + describe(packet.workoutNumbers));

        if (!packet.workoutNumbers.isEmpty()) {
            GetWorkoutTotalsRequest nextRequest = new GetWorkoutTotalsRequest(
                    this.supportProvider,
                    packet.workoutNumbers.remove(0),
                    packet.workoutNumbers
            );
            nextRequest.setFinalizeReq(this.finalizeReq);
            this.nextRequest(nextRequest);
        } else {
            this.supportProvider.endOfWorkoutSync();
        }
    }
}
