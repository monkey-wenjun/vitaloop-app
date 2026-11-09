package nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.requests;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.List;

import nodomain.freeyourgadget.gadgetbridge.devices.huawei.HuaweiPacket;
import nodomain.freeyourgadget.gadgetbridge.devices.huawei.packets.MusicControl;
import nodomain.freeyourgadget.gadgetbridge.service.devices.huawei.IHuaweiSupport;

public class GetMusicPlaylist extends Request {
    private final Logger LOG = LoggerFactory.getLogger(GetMusicPlaylist.class);

    public GetMusicPlaylist(IHuaweiSupport support) {
        super(support);
        this.serviceId = MusicControl.id;
        this.commandId = MusicControl.MusicPlaylists.id;
    }

    @Override
    protected List<byte[]> createRequest() throws Request.RequestCreationException {
        try {
            return new MusicControl.MusicPlaylists.Request(paramsProvider).serialize();
        } catch (HuaweiPacket.CryptoException e) {
            throw new Request.RequestCreationException(e);
        }
    }

    @Override
    protected void processResponse() throws Request.ResponseParseException {
        LOG.info("MusicControl.MusicPlaylists processResponse");
        if (!(receivedPacket instanceof MusicControl.MusicPlaylists.Response))
            throw new Request.ResponseTypeMismatchException(receivedPacket, MusicControl.MusicPlaylists.Response.class);

        MusicControl.MusicPlaylists.Response resp = (MusicControl.MusicPlaylists.Response) (receivedPacket);
        LOG.info("MusicPlaylists: size={}", resp.playlists == null ? 0 : resp.playlists.size());
        supportProvider.onMusicPlaylistResponse(
                resp.playlists == null
                        ? java.util.Collections.<MusicControl.MusicPlaylists.Response.PlaylistData>emptyList()
                        : resp.playlists
        );
    }
}
