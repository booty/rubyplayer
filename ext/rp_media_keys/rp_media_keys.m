#import <Foundation/Foundation.h>
#import <MediaPlayer/MediaPlayer.h>

typedef void (*rp_media_command_callback)(int command);
static rp_media_command_callback callback;
static NSMutableArray *command_targets;

void rp_media_keys_start(rp_media_command_callback handler) {
    callback = handler;
    MPRemoteCommandCenter *center = [MPRemoteCommandCenter sharedCommandCenter];
    command_targets = [NSMutableArray new];
    NSArray *commands = @[center.togglePlayPauseCommand, center.nextTrackCommand,
                          center.previousTrackCommand, center.playCommand, center.pauseCommand];
    for (NSUInteger index = 0; index < commands.count; index++) {
        MPRemoteCommand *command = commands[index];
        int command_id = (int)index + 1;
        id target = [command addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
            if (!callback) return MPRemoteCommandHandlerStatusCommandFailed;
            callback(command_id);
            return MPRemoteCommandHandlerStatusSuccess;
        }];
        [command_targets addObject:@[command, target]];
        command.enabled = YES;
    }
}

void rp_media_keys_update(const char *title, const char *artist, const char *album,
                          double duration_s, double position_s, int state) {
    MPNowPlayingInfoCenter *center = [MPNowPlayingInfoCenter defaultCenter];
    if (!title || state == 0) {
        center.nowPlayingInfo = nil;
        center.playbackState = MPNowPlayingPlaybackStateStopped;
        return;
    }
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[MPMediaItemPropertyTitle] = [NSString stringWithUTF8String:title];
    if (artist) info[MPMediaItemPropertyArtist] = [NSString stringWithUTF8String:artist];
    if (album) info[MPMediaItemPropertyAlbumTitle] = [NSString stringWithUTF8String:album];
    if (duration_s > 0) info[MPMediaItemPropertyPlaybackDuration] = @(duration_s);
    info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = @(position_s);
    info[MPNowPlayingInfoPropertyPlaybackRate] = @(state == 1 ? 1.0 : 0.0);
    center.nowPlayingInfo = info;
    center.playbackState = state == 1 ? MPNowPlayingPlaybackStatePlaying : MPNowPlayingPlaybackStatePaused;
}

void rp_media_keys_stop(void) {
    callback = NULL;
    for (NSArray *pair in command_targets) [pair[0] removeTarget:pair[1]];
    command_targets = nil;
    MPNowPlayingInfoCenter *center = [MPNowPlayingInfoCenter defaultCenter];
    center.nowPlayingInfo = nil;
    center.playbackState = MPNowPlayingPlaybackStateStopped;
}
