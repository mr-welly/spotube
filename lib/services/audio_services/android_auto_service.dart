import 'package:audio_service/audio_service.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/services/logger/logger.dart';
import 'package:spotube/services/metadata/metadata.dart';

/// Real Android Auto / MediaBrowser tree backed by the user's actual Spotube library.
///
/// Android Auto head units draw ALL UI themselves - an app can never supply custom
/// templates. The only thing an app controls is the *content* of the browse tree and
/// the playback it triggers. So this class does exactly that: it maps real playlists,
/// liked tracks and albums into `MediaItem`s the host can render, and it plays real
/// tracks through the normal Spotube audio pipeline.
///
/// See skill `android-auto-custom-ui-blocked` for why no custom car UI is possible.
class AndroidAutoService {
  AndroidAutoService(this._metadata);

  final Future<MetadataPlugin?> Function() _metadata;

  // --- Node ids -------------------------------------------------------------
  // `$_` prefix keeps our nodes from ever colliding with a real Spotify id.
  static const String rootId = 'root';

  static const String nodeLiked = r'$liked';
  static const String nodePlaylists = r'$playlists';
  static const String nodeAlbums = r'$albums';

  static String playlistNode(String id) => r'$pl_' + id;
  static String albumNode(String id) => r'$alb_' + id;

  static bool _isOurs(String id) => id.startsWith(r'$');

  Future<MetadataPlugin?> get _plugin => _metadata();

  // --- Mapping --------------------------------------------------------------

  /// `asUri` is an extension on the whole image list and already falls back to the
  /// bundled placeholder when empty, so there is no null case to handle here.
  static Uri _artOf(List<SpotubeImageObject> images) =>
      images.asUri(placeholder: ImagePlaceholder.albumArt);

  static MediaItem _trackToItem(
    SpotubeTrackObject track, {
    String? albumId,
  }) {
    return MediaItem(
      id: track.id,
      title: track.name,
      artist: track.artists.asString(),
      album: track.album.name,
      duration: Duration(milliseconds: track.durationMs),
      artUri: _artOf(track.album.images),
      playable: true,
      extras: {
        if (albumId != null) 'albumId': albumId,
        'source': 'Spotube',
      },
    );
  }

  static MediaItem _playlistToItem(SpotubeSimplePlaylistObject playlist) {
    return MediaItem(
      id: playlistNode(playlist.id),
      title: playlist.name,
      album: playlist.owner.name,
      artUri: _artOf(playlist.images),
      playable: false,
      displayDescription:
          playlist.description.isEmpty ? null : playlist.description,
    );
  }

  static MediaItem _albumToItem(SpotubeSimpleAlbumObject album) {
    final date = album.releaseDate;
    final year = date != null && date.length >= 4 ? date.substring(0, 4) : '';
    return MediaItem(
      id: albumNode(album.id),
      title: album.name,
      artist: album.artists.asString(),
      artUri: _artOf(album.images),
      playable: false,
      displayDescription: year.isEmpty ? null : year,
    );
  }

  // --- Tree ----------------------------------------------------------------

  Future<List<MediaItem>> getChildren(String parentMediaId) async {
    final plugin = await _plugin;
    if (plugin == null) {
      AppLogger.log.w(
        'AndroidAutoService: metadata plugin unavailable, tree is empty',
      );
      return const [];
    }

    try {
      if (parentMediaId.isEmpty ||
          parentMediaId == '/' ||
          parentMediaId == rootId) {
        return const [
          MediaItem(
            id: nodeLiked,
            title: 'Liked Songs',
            playable: false,
            displayDescription: 'Your saved tracks',
          ),
          MediaItem(
            id: nodePlaylists,
            title: 'Playlists',
            playable: false,
            displayDescription: 'Your Spotify playlists',
          ),
          MediaItem(
            id: nodeAlbums,
            title: 'Albums',
            playable: false,
            displayDescription: 'Saved albums',
          ),
        ];
      }

      if (parentMediaId == nodeLiked) {
        final res = await plugin.user.savedTracks(limit: 100);
        return res.items.map(_trackToItem).toList();
      }

      if (parentMediaId == nodePlaylists) {
        final res = await plugin.user.savedPlaylists(limit: 100);
        return res.items.map(_playlistToItem).toList();
      }

      if (parentMediaId == nodeAlbums) {
        final res = await plugin.user.savedAlbums(limit: 100);
        return res.items.map(_albumToItem).toList();
      }

      if (parentMediaId.startsWith(r'$pl_')) {
        final id = parentMediaId.substring(4);
        final res = await plugin.playlist.tracks(id, limit: 200);
        return res.items.map((t) => _trackToItem(t, albumId: id)).toList();
      }

      if (parentMediaId.startsWith(r'$alb_')) {
        final id = parentMediaId.substring(5);
        final res = await plugin.album.tracks(id, limit: 200);
        return res.items.map((t) => _trackToItem(t, albumId: id)).toList();
      }

      return const [];
    } catch (e, stack) {
      AppLogger.reportError(e, stack);
      return const [];
    }
  }

  Future<MediaItem?> getItem(String mediaId) async {
    final plugin = await _plugin;
    if (plugin == null) return null;

    try {
      // A leaf track id - fetch the real track so metadata/art are accurate.
      if (!_isOurs(mediaId)) {
        final track = await plugin.track.getTrack(mediaId);
        return _trackToItem(track);
      }

      for (final child in await getChildren(mediaId)) {
        if (child.id == mediaId) return child;
      }
      return null;
    } catch (e, stack) {
      AppLogger.reportError(e, stack);
      return null;
    }
  }

  Future<List<MediaItem>> search(String query) async {
    final plugin = await _plugin;
    final q = query.trim();
    if (plugin == null || q.isEmpty) return const [];

    try {
      final res = await plugin.search.tracks(q, limit: 40);
      return res.items.map(_trackToItem).toList();
    } catch (e, stack) {
      AppLogger.reportError(e, stack);
      return const [];
    }
  }

  /// Resolve a browsed track id back to the real object so the player can queue it.
  Future<SpotubeTrackObject?> resolveTrack(String mediaId) async {
    final plugin = await _plugin;
    if (plugin == null || _isOurs(mediaId)) return null;

    try {
      return await plugin.track.getTrack(mediaId);
    } catch (e, stack) {
      AppLogger.reportError(e, stack);
      return null;
    }
  }

  /// Toggle the saved state of a track. Returns true if it is now saved.
  Future<bool> toggleSaved(String trackId) async {
    final plugin = await _plugin;
    if (plugin == null) return false;

    try {
      final isSaved = await plugin.user.isSavedTracks([trackId]);
      final saved = isSaved.isNotEmpty && isSaved.first;

      if (saved) {
        await plugin.track.unsave([trackId]);
      } else {
        await plugin.track.save([trackId]);
      }
      return !saved;
    } catch (e, stack) {
      AppLogger.reportError(e, stack);
      return false;
    }
  }
}
