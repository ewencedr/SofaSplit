// SteamLobbyEmu — gives every split-screen instance its own Steam identity for multiplayer.
//
// All instances run on the same Steam account, so Steam lobbies and P2P messages between them are
// impossible (you can't join your own lobby). On Windows, Nucleus Co-op swaps in a whole Steam
// emulator; here we only emulate the multiplayer surface and keep the real Steam client for
// everything else (login, DLC ownership, Steam Input, achievements, cloud):
//
//   * ISteamUser::GetSteamID            -> a per-player fake Steam ID
//   * ISteamMatchmaking lobbies          -> hosted in-process by the lobby owner, replicated to members
//   * ISteamNetworkingMessages and the legacy ISteamNetworking P2P API
//                                         -> delivered between instances over local Unix datagram sockets
//   * RequestLobbyList                   -> the lobbies hosted by the other instances
//   * ISteamFriends names/avatars        -> the real account's, suffixed with the player number
//   * Steam callbacks / call results     -> injected into Steamworks' manual dispatch loop (current SDKs), or
//                                           run on the game's registered callback objects in SteamAPI_RunCallbacks
//                                           (older Steamworks.NET)
//
// Instances find each other through sockets in SOFASPLIT_STEAM_EMU_DIR (p<N>.sock); the player number is
// encoded in every fake Steam ID and lobby ID. Layouts follow the Steamworks SDK (callbacks pack 4).

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stddef.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

void SofaSplitHookLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
#define EmuLog(...) SofaSplitHookLog(@"SteamEmu: " __VA_ARGS__)

#pragma mark - Steamworks layouts

#pragma pack(push, 4)
typedef struct { int32_t hSteamUser; int32_t iCallback; uint8_t *pubParam; int32_t cubParam; } NHCallbackMsg;
typedef struct { int32_t eResult; uint64_t lobby; } NHLobbyCreated;                                  // 513
typedef struct { uint64_t lobby; uint32_t permissions; bool locked; uint32_t response; } NHLobbyEnter; // 504
typedef struct { uint64_t lobby; uint64_t member; uint8_t success; } NHLobbyDataUpdate;               // 505
typedef struct { uint64_t lobby, userChanged, makingChange; uint32_t stateChange; } NHLobbyChatUpdate; // 506
typedef struct { uint32_t lobbiesMatching; } NHLobbyMatchList;                                        // 510
typedef struct { uint64_t asyncCall; int32_t iCallback; uint32_t cubParam; } NHCallCompleted;         // 703
typedef struct { uint64_t remote; } NHP2PSessionRequest;                                              // 1202
typedef struct {
    uint8_t active, connecting, error, usingRelay;
    int32_t bytesQueued, packetsQueued;
    uint32_t remoteIP;
    uint16_t remotePort;
} NHP2PSessionState;
#pragma pack(pop)

// CCallbackBase from the Steamworks SDK, as older Steamworks.NET builds it: a C++ object whose vtable holds
// Run(param) and Run(param, ioFailure, call).
typedef struct { void **vtable; uint8_t flags; int32_t iCallback; } NHCallbackBase;
typedef void (*NHRunCallback)(void *self, void *param);
typedef void (*NHRunCallResult)(void *self, void *param, bool ioFailure, uint64_t call);

#pragma pack(push, 1)
typedef struct {
    int32_t type;  // 16 = k_ESteamNetworkingIdentityType_SteamID
    int32_t size;
    union { uint64_t steamID; uint8_t raw[128]; };
} NHNetIdentity;
#pragma pack(pop)

typedef struct NHNetMessage {
    void *data;
    int32_t size;
    uint32_t conn;
    NHNetIdentity peer;
    int64_t connUserData;
    int64_t usecTimeReceived;
    int64_t messageNumber;
    void (*freeData)(struct NHNetMessage *);
    void (*release)(struct NHNetMessage *);
    int32_t channel;
    int32_t flags;
    int64_t userData;
    uint16_t lane;
    uint16_t pad;
} NHNetMessage;

_Static_assert(sizeof(NHNetIdentity) == 136, "SteamNetworkingIdentity");
_Static_assert(offsetof(NHNetMessage, connUserData) == 152, "SteamNetworkingMessage_t");
_Static_assert(offsetof(NHNetMessage, channel) == 192, "SteamNetworkingMessage_t");
_Static_assert(sizeof(NHLobbyEnter) == 20 && sizeof(NHLobbyCreated) == 12 && sizeof(NHCallbackMsg) == 20, "callbacks");
_Static_assert(sizeof(NHP2PSessionState) == 20, "P2PSessionState_t");

enum { kLobbyEnter = 504, kLobbyDataUpdate = 505, kLobbyChatUpdate = 506, kLobbyCreated = 513,
       kLobbyMatchList = 510, kCallCompleted = 703, kP2PSessionRequest = 1202, kSessionRequest = 1251 };
enum { kResultOK = 1, kResultFail = 2, kResultNoConnection = 3 };
enum { kChatEntered = 1, kChatLeft = 2 };
enum { kMaxQueuedPerChannel = 4096 };
enum { kEnterSuccess = 1, kEnterDoesntExist = 2 };

#pragma mark - Identities

// Instance 4 (k_unSteamUserWebInstance) is valid for an individual account but never used by desktop clients,
// so fake IDs can't coincide with a real user's 64-bit Steam ID.
static const uint64_t kFakeUserHigh = 0x01100004ULL;   // public universe, individual account, web instance
static const uint64_t kFakeLobbyHigh = 0x01860000ULL;  // public universe, chat (lobby)
static const uint32_t kFakeAccount = 0x53530000;       // "SS"

static uint64_t FakeSteamID(int player) { return (kFakeUserHigh << 32) | (kFakeAccount + (uint32_t)player); }

static int PlayerOfSteamID(uint64_t id) {
    uint32_t account = (uint32_t)id;
    if ((id >> 32) != kFakeUserHigh || account <= kFakeAccount || account > kFakeAccount + 64) return 0;
    return (int)(account - kFakeAccount);
}

static int PlayerOfLobby(uint64_t id) {
    if ((id >> 32) != kFakeLobbyHigh || ((uint32_t)id & 0xFF000000) != 0x53000000) return 0;
    return (int)(id & 0xFF);
}

#pragma mark - State

@interface NHLobby : NSObject
@property uint64_t lobbyID, owner;
@property NSMutableArray<NSNumber *> *members;
@property NSMutableDictionary<NSString *, NSString *> *data;
@property NSMutableDictionary<NSNumber *, NSMutableDictionary<NSString *, NSString *> *> *memberData;
@property BOOL joinable;
@end
@implementation NHLobby
- (instancetype)init {
    if ((self = [super init])) {
        _members = [NSMutableArray array];
        _data = [NSMutableDictionary dictionary];
        _memberData = [NSMutableDictionary dictionary];
        _joinable = YES;
    }
    return self;
}
@end

static BOOL gEnabled;
static int gPlayer;
static NSString *gDir;
static int gSocket = -1;
static NSRecursiveLock *gLock;
static uint64_t gRealSteamID;
static void *gSteamLib;

static NSMutableArray<NSArray *> *gPending;                       // @[@(callbackID), NSData]
static NSData *gDelivering;                                       // our callback currently handed out
static NSMutableDictionary<NSNumber *, NSArray *> *gCallResults;  // handle -> @[@(callbackID), NSData]
static uint64_t gNextCall = 0x5353000000000001ULL;
static NSMutableDictionary<NSNumber *, NHLobby *> *gLobbies;
static NSMutableDictionary<NSNumber *, NSNumber *> *gJoining;     // lobby -> JoinLobby call handle
static NSMutableDictionary<NSNumber *, NSMutableArray<NSArray *> *> *gInbox;  // channel -> @[@(from), NSData]
static NSMutableSet<NSNumber *> *gSessions;
static NSMutableDictionary<NSString *, NSData *> *gCStrings;      // stable C strings handed to the game
static int64_t gMessageNumber;
static NSMutableSet<NSNumber *> *gIssuedCalls;                     // every call handle we made up
// Legacy ISteamNetworking
static NSMutableDictionary<NSNumber *, NSMutableArray<NSArray *> *> *gLegacyInbox;  // channel -> @[@(from), NSData]
static NSMutableSet<NSNumber *> *gLegacyPeers;
// Lobby list
static uint64_t gListCall;
static CFAbsoluteTime gListStarted;
static NSMutableOrderedSet<NSNumber *> *gListSeen;
static NSArray<NSNumber *> *gLobbyList = @[];
// Registered callbacks (older Steamworks.NET)
static BOOL gManualDispatch;
static NSMutableDictionary<NSNumber *, NSMutableArray<NSValue *> *> *gRegistered;  // callback ID -> objects
static NSMutableDictionary<NSNumber *, NSValue *> *gCallResultTargets;             // our call handle -> object

static uint64_t MySteamID(void) { return FakeSteamID(gPlayer); }

static const char *StableCString(NSString *s) {
    s = s ?: @"";
    NSData *d = gCStrings[s];
    if (!d) {
        NSMutableData *m = [[s dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
        [m appendBytes:"\0" length:1];
        gCStrings[s] = d = m;
    }
    return d.bytes;
}

static void EnqueueCallback(int callbackID, const void *payload, size_t size) {
    [gPending addObject:@[ @(callbackID), [NSData dataWithBytes:payload length:size] ]];
}

static uint64_t NewCallHandle(void) {
    uint64_t handle = gNextCall++;
    [gIssuedCalls addObject:@(handle)];
    return handle;
}

static uint64_t NewCallResult(int callbackID, const void *payload, size_t size) {
    uint64_t handle = NewCallHandle();
    gCallResults[@(handle)] = @[ @(callbackID), [NSData dataWithBytes:payload length:size] ];
    NHCallCompleted done = {handle, callbackID, (uint32_t)size};
    EnqueueCallback(kCallCompleted, &done, sizeof done);
    return handle;
}

static void EnqueueDataUpdate(uint64_t lobby, uint64_t member, BOOL success) {
    NHLobbyDataUpdate u = {lobby, member, success};
    EnqueueCallback(kLobbyDataUpdate, &u, sizeof u);
}

static void EnqueueChatUpdate(uint64_t lobby, uint64_t user, uint32_t state) {
    NHLobbyChatUpdate u = {lobby, user, user, state};
    EnqueueCallback(kLobbyChatUpdate, &u, sizeof u);
}

#pragma mark - Transport

enum { kMsgP2P = 1, kMsgJoin, kMsgLeave, kMsgState, kMsgDataRequest, kMsgSetMemberData, kMsgClosed, kMsgJoinDenied,
       kMsgLegacyP2P, kMsgListRequest };

typedef struct {
    uint32_t magic;  // 'SOFA'
    uint32_t type;
    uint64_t from;
    uint64_t lobby;
    int32_t channel;
    int32_t flags;
} NHWireHeader;

static const uint32_t kWireMagic = 0x534F4641;

static NSString *SocketPath(int player) { return [gDir stringByAppendingFormat:@"/p%d.sock", player]; }

static void OpenSocket(void) {
    if (gSocket >= 0) return;
    [[NSFileManager defaultManager] createDirectoryAtPath:gDir withIntermediateDirectories:YES attributes:nil error:nil];
    gSocket = socket(AF_UNIX, SOCK_DGRAM, 0);
    int buf = 8 << 20;
    setsockopt(gSocket, SOL_SOCKET, SO_SNDBUF, &buf, sizeof buf);
    setsockopt(gSocket, SOL_SOCKET, SO_RCVBUF, &buf, sizeof buf);
    struct sockaddr_un addr = {.sun_family = AF_UNIX};
    strlcpy(addr.sun_path, SocketPath(gPlayer).fileSystemRepresentation, sizeof addr.sun_path);
    unlink(addr.sun_path);
    if (bind(gSocket, (struct sockaddr *)&addr, sizeof addr) != 0) EmuLog(@"bind %s failed: %s", addr.sun_path, strerror(errno));
    else EmuLog(@"player %d listening on %s as %llu", gPlayer, addr.sun_path, MySteamID());
}

static BOOL Send(int player, uint32_t type, uint64_t lobby, int32_t channel, NSData *payload) {
    NSMutableData *packet = [NSMutableData dataWithLength:sizeof(NHWireHeader)];
    NHWireHeader *h = packet.mutableBytes;
    *h = (NHWireHeader){kWireMagic, type, MySteamID(), lobby, channel, 0};
    if (payload) [packet appendData:payload];
    struct sockaddr_un addr = {.sun_family = AF_UNIX};
    strlcpy(addr.sun_path, SocketPath(player).fileSystemRepresentation, sizeof addr.sun_path);
    ssize_t sent = sendto(gSocket, packet.bytes, packet.length, MSG_DONTWAIT, (struct sockaddr *)&addr, sizeof addr);
    if (sent < 0 && type != kMsgP2P) EmuLog(@"send type %u to player %d failed: %s", type, player, strerror(errno));
    return sent == (ssize_t)packet.length;
}

static NSData *SerializeLobby(NHLobby *l) {
    NSMutableDictionary *memberData = [NSMutableDictionary dictionary];
    [l.memberData enumerateKeysAndObjectsUsingBlock:^(NSNumber *k, NSDictionary *v, BOOL *stop) {
        memberData[k.stringValue] = v;
    }];
    NSDictionary *plist = @{@"owner" : @(l.owner), @"members" : l.members, @"data" : l.data,
                            @"memberData" : memberData, @"joinable" : @(l.joinable)};
    return [NSPropertyListSerialization dataWithPropertyList:plist format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
}

static void ApplyLobbyState(NHLobby *l, NSData *data) {
    NSDictionary *p = [NSPropertyListSerialization propertyListWithData:data options:0 format:nil error:nil];
    if (![p isKindOfClass:[NSDictionary class]]) return;
    l.owner = [p[@"owner"] unsignedLongLongValue];
    l.members = [p[@"members"] mutableCopy] ?: [NSMutableArray array];
    l.data = [p[@"data"] mutableCopy] ?: [NSMutableDictionary dictionary];
    l.joinable = [p[@"joinable"] boolValue];
    NSMutableDictionary *md = [NSMutableDictionary dictionary];
    [(NSDictionary *)p[@"memberData"] enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSDictionary *v, BOOL *stop) {
        md[@(strtoull(k.UTF8String, NULL, 10))] = [v mutableCopy];
    }];
    l.memberData = md;
}

/// Player numbers of the other instances running right now (their sockets in the shared directory).
static NSArray<NSNumber *> *OtherPlayers(void) {
    NSMutableArray *players = [NSMutableArray array];
    for (NSString *name in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:gDir error:nil]) {
        int p = 0;
        if (sscanf(name.UTF8String, "p%d.sock", &p) == 1 && p > 0 && p != gPlayer) [players addObject:@(p)];
    }
    return players;
}

static void BroadcastLobby(NHLobby *l) {
    NSData *state = SerializeLobby(l);
    for (NSNumber *m in l.members) {
        int p = PlayerOfSteamID(m.unsignedLongLongValue);
        if (p && p != gPlayer) Send(p, kMsgState, l.lobbyID, 0, state);
    }
}

#pragma mark - Incoming

static void HandlePacket(const uint8_t *bytes, size_t len) {
    if (len < sizeof(NHWireHeader)) return;
    NHWireHeader h;
    memcpy(&h, bytes, sizeof h);
    if (h.magic != kWireMagic) return;
    NSData *payload = [NSData dataWithBytes:bytes + sizeof h length:len - sizeof h];
    int fromPlayer = PlayerOfSteamID(h.from);
    NHLobby *lobby = gLobbies[@(h.lobby)];
    BOOL iOwn = lobby && lobby.owner == MySteamID();

    switch (h.type) {
    case kMsgP2P: {
        if (![gSessions containsObject:@(h.from)]) {
            [gSessions addObject:@(h.from)];
            NHNetIdentity ident = {16, 8, {.steamID = h.from}};
            EnqueueCallback(kSessionRequest, &ident, sizeof ident);
        }
        NSMutableArray *box = gInbox[@(h.channel)] ?: (gInbox[@(h.channel)] = [NSMutableArray array]);
        // A channel the game never reads must not grow forever (Steam drops unread messages too).
        if (box.count >= kMaxQueuedPerChannel) [box removeObjectAtIndex:0];
        [box addObject:@[ @(h.from), payload ]];
        break;
    }
    case kMsgLegacyP2P: {
        if (![gLegacyPeers containsObject:@(h.from)]) {
            [gLegacyPeers addObject:@(h.from)];
            NHP2PSessionRequest request = {h.from};
            EnqueueCallback(kP2PSessionRequest, &request, sizeof request);
        }
        NSMutableArray *box = gLegacyInbox[@(h.channel)] ?: (gLegacyInbox[@(h.channel)] = [NSMutableArray array]);
        if (box.count >= kMaxQueuedPerChannel) [box removeObjectAtIndex:0];
        [box addObject:@[ @(h.from), payload ]];
        break;
    }
    case kMsgListRequest:
        for (NHLobby *l in gLobbies.allValues)
            if (l.owner == MySteamID() && l.joinable) Send(fromPlayer, kMsgState, l.lobbyID, 0, SerializeLobby(l));
        break;
    case kMsgJoin:
        if (!iOwn || !lobby.joinable) {
            Send(fromPlayer, kMsgJoinDenied, h.lobby, 0, nil);
            break;
        }
        if (![lobby.members containsObject:@(h.from)]) {
            [lobby.members addObject:@(h.from)];
            EmuLog(@"player %d joined lobby %llu", fromPlayer, h.lobby);
            EnqueueChatUpdate(lobby.lobbyID, h.from, kChatEntered);
        }
        BroadcastLobby(lobby);
        EnqueueDataUpdate(lobby.lobbyID, lobby.lobbyID, YES);
        break;
    case kMsgLeave:
        if (iOwn && [lobby.members containsObject:@(h.from)]) {
            [lobby.members removeObject:@(h.from)];
            [lobby.memberData removeObjectForKey:@(h.from)];
            EmuLog(@"player %d left lobby %llu", fromPlayer, h.lobby);
            EnqueueChatUpdate(lobby.lobbyID, h.from, kChatLeft);
            BroadcastLobby(lobby);
        }
        break;
    case kMsgDataRequest:
        if (lobby) Send(fromPlayer, kMsgState, h.lobby, 0, SerializeLobby(lobby));
        break;
    case kMsgSetMemberData:
        if (iOwn && [lobby.members containsObject:@(h.from)]) {
            NSDictionary *kv = [NSPropertyListSerialization propertyListWithData:payload options:0 format:nil error:nil];
            NSMutableDictionary *md = lobby.memberData[@(h.from)] ?: (lobby.memberData[@(h.from)] = [NSMutableDictionary dictionary]);
            if ([kv isKindOfClass:[NSDictionary class]]) [md addEntriesFromDictionary:kv];
            BroadcastLobby(lobby);
            EnqueueDataUpdate(lobby.lobbyID, h.from, YES);
        }
        break;
    case kMsgState: {
        BOOL known = lobby != nil;
        NSArray *before = known ? [lobby.members copy] : @[];
        if (!lobby) {
            lobby = [NHLobby new];
            lobby.lobbyID = h.lobby;
            gLobbies[@(h.lobby)] = lobby;
        }
        ApplyLobbyState(lobby, payload);
        if (gListCall && lobby.owner != MySteamID() && lobby.joinable) [gListSeen addObject:@(h.lobby)];
        NSNumber *joinHandle = gJoining[@(h.lobby)];
        BOOL amMember = [lobby.members containsObject:@(MySteamID())];
        if (joinHandle && amMember) {
            [gJoining removeObjectForKey:@(h.lobby)];
            NHLobbyEnter enter = {h.lobby, 0, false, kEnterSuccess};
            gCallResults[joinHandle] = @[ @(kLobbyEnter), [NSData dataWithBytes:&enter length:sizeof enter] ];
            NHCallCompleted done = {joinHandle.unsignedLongLongValue, kLobbyEnter, sizeof enter};
            EnqueueCallback(kCallCompleted, &done, sizeof done);
            EnqueueCallback(kLobbyEnter, &enter, sizeof enter);
            EmuLog(@"entered lobby %llu (owner %llu, %lu members)", h.lobby, lobby.owner, (unsigned long)lobby.members.count);
        } else if (known && [before containsObject:@(MySteamID())]) {
            for (NSNumber *m in lobby.members)
                if (![before containsObject:m]) EnqueueChatUpdate(h.lobby, m.unsignedLongLongValue, kChatEntered);
            for (NSNumber *m in before)
                if (![lobby.members containsObject:m]) EnqueueChatUpdate(h.lobby, m.unsignedLongLongValue, kChatLeft);
        }
        EnqueueDataUpdate(h.lobby, h.lobby, YES);
        // Per-member updates only once we're in: the game ignores (and logs errors for) unknown players.
        if (amMember)
            for (NSNumber *m in lobby.members) EnqueueDataUpdate(h.lobby, m.unsignedLongLongValue, YES);
        break;
    }
    case kMsgClosed:
        if (lobby && !iOwn) {
            uint64_t owner = lobby.owner;
            [gLobbies removeObjectForKey:@(h.lobby)];
            EmuLog(@"host closed lobby %llu", h.lobby);
            EnqueueChatUpdate(h.lobby, owner, kChatLeft);
        }
        break;
    case kMsgJoinDenied: {
        NSNumber *joinHandle = gJoining[@(h.lobby)];
        if (!joinHandle) break;
        [gJoining removeObjectForKey:@(h.lobby)];
        NHLobbyEnter enter = {h.lobby, 0, false, kEnterDoesntExist};
        gCallResults[joinHandle] = @[ @(kLobbyEnter), [NSData dataWithBytes:&enter length:sizeof enter] ];
        NHCallCompleted done = {joinHandle.unsignedLongLongValue, kLobbyEnter, sizeof enter};
        EnqueueCallback(kCallCompleted, &done, sizeof done);
        EnqueueCallback(kLobbyEnter, &enter, sizeof enter);
        break;
    }
    }
}

static void Pump(void) {
    static uint8_t *buf;
    const size_t cap = 1 << 20;
    if (!buf) buf = malloc(cap);
    for (;;) {
        ssize_t n = recv(gSocket, buf, cap, MSG_DONTWAIT);
        if (n <= 0) break;
        @autoreleasepool {
            HandlePacket(buf, (size_t)n);
        }
    }
    // Answers to RequestLobbyList come from every instance within a few milliseconds; collect them briefly.
    if (gListCall && CFAbsoluteTimeGetCurrent() - gListStarted > 0.3) {
        gLobbyList = gListSeen.array;
        NHLobbyMatchList list = {(uint32_t)gLobbyList.count};
        gCallResults[@(gListCall)] = @[ @(kLobbyMatchList), [NSData dataWithBytes:&list length:sizeof list] ];
        NHCallCompleted done = {gListCall, kLobbyMatchList, sizeof list};
        EnqueueCallback(kCallCompleted, &done, sizeof done);
        EmuLog(@"lobby list: %lu lobbies from other players", (unsigned long)gLobbyList.count);
        gListCall = 0;
    }
}

#pragma mark - Replacements: dispatch

typedef bool (*GetNextCallback_t)(int32_t, NHCallbackMsg *);
typedef void (*FreeLastCallback_t)(int32_t);
typedef bool (*GetAPICallResult_t)(int32_t, uint64_t, void *, int, int, bool *);
typedef int32_t (*GetHSteamUser_t)(void);
static GetNextCallback_t oGetNextCallback;
static FreeLastCallback_t oFreeLastCallback;
static GetAPICallResult_t oGetAPICallResult;

static bool E_GetNextCallback(int32_t pipe, NHCallbackMsg *msg) {
    [gLock lock];
    Pump();
    if (gPending.count) {
        NSArray *next = gPending.firstObject;
        [gPending removeObjectAtIndex:0];
        gDelivering = next[1];
        static GetHSteamUser_t getUser;
        if (!getUser && gSteamLib) getUser = (GetHSteamUser_t)dlsym(gSteamLib, "SteamAPI_GetHSteamUser");
        msg->hSteamUser = getUser ? getUser() : 1;
        msg->iCallback = [next[0] intValue];
        msg->pubParam = (uint8_t *)gDelivering.bytes;
        msg->cubParam = (int32_t)gDelivering.length;
        [gLock unlock];
        return true;
    }
    [gLock unlock];
    return oGetNextCallback(pipe, msg);
}

static void E_FreeLastCallback(int32_t pipe) {
    [gLock lock];
    BOOL ours = gDelivering != nil;
    gDelivering = nil;
    [gLock unlock];
    if (!ours) oFreeLastCallback(pipe);
}

static bool E_GetAPICallResult(int32_t pipe, uint64_t call, void *out, int cub, int expected, bool *failed) {
    [gLock lock];
    NSArray *result = gCallResults[@(call)];
    if (result) {
        [gCallResults removeObjectForKey:@(call)];
        NSData *d = result[1];
        memset(out, 0, (size_t)cub);
        memcpy(out, d.bytes, MIN((size_t)cub, d.length));
        if (failed) *failed = false;
        [gLock unlock];
        return true;
    }
    [gLock unlock];
    return oGetAPICallResult(pipe, call, out, cub, expected, failed);
}

#pragma mark - Replacements: user / friends

typedef uint64_t (*GetSteamID_t)(void *);
typedef const char *(*GetPersonaName_t)(void *);
typedef int (*GetAvatar_t)(void *, uint64_t);
static GetSteamID_t oGetSteamID;
static GetAvatar_t oLargeAvatar, oMediumAvatar, oSmallAvatar;
static const char *(*oFriendPersonaName)(void *, uint64_t);

static uint64_t E_GetSteamID(void *self) {
    if (!gRealSteamID && oGetSteamID) gRealSteamID = oGetSteamID(self);
    return MySteamID();
}

static const char *E_GetFriendPersonaName(void *self, uint64_t id) {
    int p = PlayerOfSteamID(id);
    if (!p) return oFriendPersonaName(self, id);
    GetPersonaName_t own = gSteamLib ? (GetPersonaName_t)dlsym(gSteamLib, "SteamAPI_ISteamFriends_GetPersonaName") : NULL;
    const char *ownName = own ? own(self) : NULL;
    NSString *base = ownName ? @(ownName) : @"Player";
    [gLock lock];
    const char *name = StableCString(p == 1 ? base : [NSString stringWithFormat:@"%@ (P%d)", base, p]);
    [gLock unlock];
    return name;
}

static int AvatarFor(GetAvatar_t orig, void *self, uint64_t id) {
    return orig(self, PlayerOfSteamID(id) && gRealSteamID ? gRealSteamID : id);
}
static int E_LargeAvatar(void *self, uint64_t id) { return AvatarFor(oLargeAvatar, self, id); }
static int E_MediumAvatar(void *self, uint64_t id) { return AvatarFor(oMediumAvatar, self, id); }
static int E_SmallAvatar(void *self, uint64_t id) { return AvatarFor(oSmallAvatar, self, id); }

#pragma mark - Replacements: matchmaking

static uint64_t E_CreateLobby(void *self, int type, int maxMembers) {
    [gLock lock];
    NHLobby *l = [NHLobby new];
    l.lobbyID = (kFakeLobbyHigh << 32) | 0x53000000 | ((uint64_t)(arc4random() & 0xFFFF) << 8) | (uint64_t)gPlayer;
    l.owner = MySteamID();
    [l.members addObject:@(MySteamID())];
    gLobbies[@(l.lobbyID)] = l;
    NHLobbyCreated created = {kResultOK, l.lobbyID};
    uint64_t handle = NewCallResult(kLobbyCreated, &created, sizeof created);
    EnqueueCallback(kLobbyCreated, &created, sizeof created);
    NHLobbyEnter enter = {l.lobbyID, 0, false, kEnterSuccess};
    EnqueueCallback(kLobbyEnter, &enter, sizeof enter);
    EmuLog(@"created lobby %llu", l.lobbyID);
    [gLock unlock];
    return handle;
}

static uint64_t E_JoinLobby(void *self, uint64_t lobbyID) {
    [gLock lock];
    uint64_t handle = NewCallHandle();
    int host = PlayerOfLobby(lobbyID);
    NHLobby *existing = gLobbies[@(lobbyID)];
    if (host == gPlayer && existing) {
        NHLobbyEnter enter = {lobbyID, 0, false, kEnterSuccess};
        gCallResults[@(handle)] = @[ @(kLobbyEnter), [NSData dataWithBytes:&enter length:sizeof enter] ];
        NHCallCompleted done = {handle, kLobbyEnter, sizeof enter};
        EnqueueCallback(kCallCompleted, &done, sizeof done);
        EnqueueCallback(kLobbyEnter, &enter, sizeof enter);
    } else if (host && Send(host, kMsgJoin, lobbyID, 0, nil)) {
        gJoining[@(lobbyID)] = @(handle);
        EmuLog(@"joining lobby %llu hosted by player %d", lobbyID, host);
    } else {
        EmuLog(@"cannot join lobby %llu (host player %d unreachable)", lobbyID, host);
        NHLobbyEnter enter = {lobbyID, 0, false, kEnterDoesntExist};
        gCallResults[@(handle)] = @[ @(kLobbyEnter), [NSData dataWithBytes:&enter length:sizeof enter] ];
        NHCallCompleted done = {handle, kLobbyEnter, sizeof enter};
        EnqueueCallback(kCallCompleted, &done, sizeof done);
        EnqueueCallback(kLobbyEnter, &enter, sizeof enter);
    }
    [gLock unlock];
    return handle;
}

static void E_LeaveLobby(void *self, uint64_t lobbyID) {
    [gLock lock];
    NHLobby *l = gLobbies[@(lobbyID)];
    if (l.owner == MySteamID()) {
        for (NSNumber *m in l.members) {
            int p = PlayerOfSteamID(m.unsignedLongLongValue);
            if (p && p != gPlayer) Send(p, kMsgClosed, lobbyID, 0, nil);
        }
    } else if (l) {
        Send(PlayerOfLobby(lobbyID), kMsgLeave, lobbyID, 0, nil);
    }
    [gLobbies removeObjectForKey:@(lobbyID)];
    [gJoining removeObjectForKey:@(lobbyID)];
    [gLock unlock];
}

static bool E_SetLobbyData(void *self, uint64_t lobbyID, const char *key, const char *value) {
    [gLock lock];
    NHLobby *l = gLobbies[@(lobbyID)];
    BOOL ok = l && l.owner == MySteamID() && key;
    if (ok) {
        l.data[@(key)] = value ? @(value) : @"";
        BroadcastLobby(l);
        EnqueueDataUpdate(lobbyID, lobbyID, YES);
    }
    [gLock unlock];
    return ok;
}

static const char *E_GetLobbyData(void *self, uint64_t lobbyID, const char *key) {
    [gLock lock];
    const char *v = StableCString(key ? gLobbies[@(lobbyID)].data[@(key)] : nil);
    [gLock unlock];
    return v;
}

static int E_GetNumLobbyMembers(void *self, uint64_t lobbyID) {
    [gLock lock];
    int n = (int)gLobbies[@(lobbyID)].members.count;
    [gLock unlock];
    return n;
}

static uint64_t E_GetLobbyMemberByIndex(void *self, uint64_t lobbyID, int index) {
    [gLock lock];
    NSArray *members = gLobbies[@(lobbyID)].members;
    uint64_t id = index >= 0 && index < (int)members.count ? [members[index] unsignedLongLongValue] : 0;
    [gLock unlock];
    return id;
}

static void E_SetLobbyMemberData(void *self, uint64_t lobbyID, const char *key, const char *value) {
    if (!key) return;
    [gLock lock];
    NHLobby *l = gLobbies[@(lobbyID)];
    if (l) {
        NSString *k = @(key), *v = value ? @(value) : @"";
        NSMutableDictionary *md = l.memberData[@(MySteamID())] ?: (l.memberData[@(MySteamID())] = [NSMutableDictionary dictionary]);
        md[k] = v;
        if (l.owner == MySteamID()) {
            BroadcastLobby(l);
            EnqueueDataUpdate(lobbyID, MySteamID(), YES);
        } else {
            NSData *kv = [NSPropertyListSerialization dataWithPropertyList:@{k : v} format:NSPropertyListBinaryFormat_v1_0
                                                                   options:0 error:nil];
            Send(PlayerOfLobby(lobbyID), kMsgSetMemberData, lobbyID, 0, kv);
        }
    }
    [gLock unlock];
}

static const char *E_GetLobbyMemberData(void *self, uint64_t lobbyID, uint64_t user, const char *key) {
    [gLock lock];
    const char *v = StableCString(key ? gLobbies[@(lobbyID)].memberData[@(user)][@(key)] : nil);
    [gLock unlock];
    return v;
}

static bool E_SetLobbyJoinable(void *self, uint64_t lobbyID, bool joinable) {
    [gLock lock];
    NHLobby *l = gLobbies[@(lobbyID)];
    if (l.owner == MySteamID()) {
        l.joinable = joinable;
        BroadcastLobby(l);
    }
    [gLock unlock];
    return l != nil;
}

static bool E_RequestLobbyData(void *self, uint64_t lobbyID) {
    [gLock lock];
    int host = PlayerOfLobby(lobbyID);
    NHLobby *l = gLobbies[@(lobbyID)];
    if (l && l.owner == MySteamID()) EnqueueDataUpdate(lobbyID, lobbyID, YES);
    else if (!host || !Send(host, kMsgDataRequest, lobbyID, 0, nil)) EnqueueDataUpdate(lobbyID, lobbyID, NO);
    [gLock unlock];
    return host != 0;
}

static uint64_t E_GetLobbyOwner(void *self, uint64_t lobbyID) {
    [gLock lock];
    uint64_t owner = gLobbies[@(lobbyID)].owner;
    [gLock unlock];
    return owner;
}

static uint64_t E_RequestLobbyList(void *self) {
    // Only the other windows' lobbies: public matchmaking would list strangers' real lobbies we can't join.
    [gLock lock];
    uint64_t handle = NewCallHandle();
    gListCall = handle;
    gListStarted = CFAbsoluteTimeGetCurrent();
    gListSeen = [NSMutableOrderedSet orderedSet];
    for (NSNumber *p in OtherPlayers()) Send(p.intValue, kMsgListRequest, 0, 0, nil);
    [gLock unlock];
    return handle;
}

static uint64_t E_GetLobbyByIndex(void *self, int index) {
    [gLock lock];
    uint64_t id = index >= 0 && index < (int)gLobbyList.count ? gLobbyList[index].unsignedLongLongValue : 0;
    [gLock unlock];
    return id;
}

static bool E_SetLobbyType(void *self, uint64_t lobbyID, int type) {
    [gLock lock];
    bool ok = gLobbies[@(lobbyID)].owner == MySteamID();
    [gLock unlock];
    return ok;
}

static bool E_SetLobbyMemberLimit(void *self, uint64_t lobbyID, int limit) { return E_SetLobbyType(self, lobbyID, 0); }

#pragma mark - Replacements: networking messages

static void ReleaseMessage(NHNetMessage *m) {
    free(m->data);
    free(m);
}

static void (*oMessageRelease)(NHNetMessage *);

static void E_MessageRelease(NHNetMessage *m) {
    if (m && m->release == ReleaseMessage) ReleaseMessage(m);
    else if (oMessageRelease) oMessageRelease(m);
}

static int32_t E_SendMessageToUser(void *self, const NHNetIdentity *who, const void *data, uint32_t size, int flags,
                                   int channel) {
    int target = who ? PlayerOfSteamID(who->steamID) : 0;
    if (!target) return kResultFail;
    [gLock lock];
    BOOL ok;
    if (target == gPlayer) {
        NSMutableArray *box = gInbox[@(channel)] ?: (gInbox[@(channel)] = [NSMutableArray array]);
        [box addObject:@[ @(MySteamID()), [NSData dataWithBytes:data length:size] ]];
        ok = YES;
    } else {
        ok = Send(target, kMsgP2P, 0, channel, [NSData dataWithBytes:data length:size]);
    }
    [gLock unlock];
    return ok ? kResultOK : kResultNoConnection;
}

static int E_ReceiveMessagesOnChannel(void *self, int channel, NHNetMessage **out, int max) {
    [gLock lock];
    Pump();
    NSMutableArray *box = gInbox[@(channel)];
    int n = 0;
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    while (box.count && n < max) {
        NSArray *entry = box.firstObject;
        [box removeObjectAtIndex:0];
        NSData *payload = entry[1];
        NHNetMessage *m = calloc(1, sizeof *m);
        m->size = (int32_t)payload.length;
        m->data = malloc(MAX(payload.length, 1));
        memcpy(m->data, payload.bytes, payload.length);
        m->peer = (NHNetIdentity){16, 8, {.steamID = [entry[0] unsignedLongLongValue]}};
        m->usecTimeReceived = (int64_t)ts.tv_sec * 1000000 + ts.tv_nsec / 1000;
        m->messageNumber = ++gMessageNumber;
        m->release = ReleaseMessage;
        m->channel = channel;
        out[n++] = m;
    }
    [gLock unlock];
    return n;
}

static bool E_AcceptSession(void *self, const NHNetIdentity *who) {
    [gLock lock];
    if (who) [gSessions addObject:@(who->steamID)];
    [gLock unlock];
    return true;
}

static bool E_CloseChannel(void *self, const NHNetIdentity *who, int channel) { return true; }

static bool E_CloseSession(void *self, const NHNetIdentity *who) {
    [gLock lock];
    if (who) [gSessions removeObject:@(who->steamID)];
    [gLock unlock];
    return true;
}

#pragma mark - Replacements: legacy ISteamNetworking

static bool (*oSendP2PPacket)(void *, uint64_t, const void *, uint32_t, int, int);
static bool (*oIsP2PPacketAvailable)(void *, uint32_t *, int);
static bool (*oReadP2PPacket)(void *, void *, uint32_t, uint32_t *, uint64_t *, int);
static bool (*oAcceptP2PSession)(void *, uint64_t);
static bool (*oCloseP2PSession)(void *, uint64_t);
static bool (*oCloseP2PChannel)(void *, uint64_t, int);
static bool (*oGetP2PSessionState)(void *, uint64_t, NHP2PSessionState *);

static bool E_SendP2PPacket(void *self, uint64_t remote, const void *data, uint32_t size, int sendType, int channel) {
    int target = PlayerOfSteamID(remote);
    if (!target) return oSendP2PPacket ? oSendP2PPacket(self, remote, data, size, sendType, channel) : false;
    [gLock lock];
    [gLegacyPeers addObject:@(remote)];
    BOOL ok;
    if (target == gPlayer) {
        NSMutableArray *box = gLegacyInbox[@(channel)] ?: (gLegacyInbox[@(channel)] = [NSMutableArray array]);
        [box addObject:@[ @(remote), [NSData dataWithBytes:data length:size] ]];
        ok = YES;
    } else {
        ok = Send(target, kMsgLegacyP2P, 0, channel, [NSData dataWithBytes:data length:size]);
    }
    [gLock unlock];
    return ok;
}

static bool E_IsP2PPacketAvailable(void *self, uint32_t *size, int channel) {
    [gLock lock];
    Pump();
    NSArray *next = gLegacyInbox[@(channel)].firstObject;
    if (next && size) *size = (uint32_t)[next[1] length];
    [gLock unlock];
    if (next) return true;
    return oIsP2PPacketAvailable ? oIsP2PPacketAvailable(self, size, channel) : false;
}

static bool E_ReadP2PPacket(void *self, void *dest, uint32_t capacity, uint32_t *size, uint64_t *remote, int channel) {
    [gLock lock];
    Pump();
    NSMutableArray *box = gLegacyInbox[@(channel)];
    NSArray *next = box.firstObject;
    if (next) {
        [box removeObjectAtIndex:0];
        NSData *payload = next[1];
        memcpy(dest, payload.bytes, MIN((NSUInteger)capacity, payload.length));
        if (size) *size = (uint32_t)payload.length;
        if (remote) *remote = [next[0] unsignedLongLongValue];
    }
    [gLock unlock];
    if (next) return true;
    return oReadP2PPacket ? oReadP2PPacket(self, dest, capacity, size, remote, channel) : false;
}

static bool E_AcceptP2PSession(void *self, uint64_t remote) {
    if (!PlayerOfSteamID(remote)) return oAcceptP2PSession ? oAcceptP2PSession(self, remote) : false;
    [gLock lock];
    [gLegacyPeers addObject:@(remote)];
    [gLock unlock];
    return true;
}

static bool E_CloseP2PSession(void *self, uint64_t remote) {
    if (!PlayerOfSteamID(remote)) return oCloseP2PSession ? oCloseP2PSession(self, remote) : false;
    [gLock lock];
    [gLegacyPeers removeObject:@(remote)];
    [gLock unlock];
    return true;
}

static bool E_CloseP2PChannel(void *self, uint64_t remote, int channel) {
    if (!PlayerOfSteamID(remote)) return oCloseP2PChannel ? oCloseP2PChannel(self, remote, channel) : false;
    return true;
}

static bool E_GetP2PSessionState(void *self, uint64_t remote, NHP2PSessionState *state) {
    if (!PlayerOfSteamID(remote)) return oGetP2PSessionState ? oGetP2PSessionState(self, remote, state) : false;
    [gLock lock];
    BOOL known = [gLegacyPeers containsObject:@(remote)];
    [gLock unlock];
    if (state) *state = (NHP2PSessionState){.active = known};
    return known;
}

#pragma mark - Replacements: registered callbacks

static void (*oRegisterCallback)(void *, int);
static void (*oUnregisterCallback)(void *);
static void (*oRegisterCallResult)(void *, uint64_t);
static void (*oUnregisterCallResult)(void *, uint64_t);
static void (*oRunCallbacks)(void);

static void E_RegisterCallback(void *object, int callbackID) {
    [gLock lock];
    NSMutableArray *list = gRegistered[@(callbackID)] ?: (gRegistered[@(callbackID)] = [NSMutableArray array]);
    [list addObject:[NSValue valueWithPointer:object]];
    [gLock unlock];
    oRegisterCallback(object, callbackID);
}

static void E_UnregisterCallback(void *object) {
    [gLock lock];
    for (NSMutableArray *list in gRegistered.allValues) [list removeObject:[NSValue valueWithPointer:object]];
    [gLock unlock];
    oUnregisterCallback(object);
}

static void E_RegisterCallResult(void *object, uint64_t call) {
    [gLock lock];
    BOOL ours = [gIssuedCalls containsObject:@(call)];
    if (ours) gCallResultTargets[@(call)] = [NSValue valueWithPointer:object];
    [gLock unlock];
    if (!ours) oRegisterCallResult(object, call);
}

static void E_UnregisterCallResult(void *object, uint64_t call) {
    [gLock lock];
    BOOL ours = [gIssuedCalls containsObject:@(call)];
    if (ours) [gCallResultTargets removeObjectForKey:@(call)];
    [gLock unlock];
    if (!ours) oUnregisterCallResult(object, call);
}

/// Runs our callbacks and call results on the objects the game registered, after Steam's own.
static void E_RunCallbacks(void) {
    oRunCallbacks();
    if (gManualDispatch) return;
    NSMutableArray<NSArray *> *callbacks = [NSMutableArray array];  // @[object, NSData]
    NSMutableArray<NSArray *> *results = [NSMutableArray array];    // @[object, NSData, handle]
    [gLock lock];
    Pump();
    for (NSArray *event in gPending)
        for (NSValue *object in gRegistered[event[0]]) [callbacks addObject:@[ object, event[1] ]];
    [gPending removeAllObjects];
    for (NSNumber *call in gCallResultTargets.allKeys) {
        NSArray *result = gCallResults[call];
        if (!result) continue;
        [results addObject:@[ gCallResultTargets[call], result[1], call ]];
        [gCallResultTargets removeObjectForKey:call];
        [gCallResults removeObjectForKey:call];
        [gIssuedCalls removeObject:call];
    }
    [gLock unlock];
    // Outside the lock: the game calls back into Steam from these.
    for (NSArray *item in callbacks) {
        NHCallbackBase *object = [item[0] pointerValue];
        ((NHRunCallback)object->vtable[0])(object, (void *)[item[1] bytes]);
    }
    for (NSArray *item in results) {
        NHCallbackBase *object = [item[0] pointerValue];
        ((NHRunCallResult)object->vtable[1])(object, (void *)[item[1] bytes], false, [item[2] unsignedLongLongValue]);
    }
}

#pragma mark - Resolution

void SofaSplitSteamEmuInit(NSDictionary<NSString *, NSString *> *env) {
    gEnabled = [env[@"SOFASPLIT_STEAM_EMU"] isEqualToString:@"1"] && env[@"SOFASPLIT_STEAM_EMU_DIR"].length;
    if (!gEnabled) return;
    gPlayer = MAX(1, env[@"SOFASPLIT_PLAYER"].intValue);
    gDir = env[@"SOFASPLIT_STEAM_EMU_DIR"];
    gLock = [NSRecursiveLock new];
    gPending = [NSMutableArray array];
    gCallResults = [NSMutableDictionary dictionary];
    gLobbies = [NSMutableDictionary dictionary];
    gJoining = [NSMutableDictionary dictionary];
    gInbox = [NSMutableDictionary dictionary];
    gSessions = [NSMutableSet set];
    gCStrings = [NSMutableDictionary dictionary];
    gIssuedCalls = [NSMutableSet set];
    gLegacyInbox = [NSMutableDictionary dictionary];
    gLegacyPeers = [NSMutableSet set];
    gRegistered = [NSMutableDictionary dictionary];
    gCallResultTargets = [NSMutableDictionary dictionary];
    OpenSocket();
}

void *SofaSplitSteamEmuResolve(void *handle, const char *symbol, void *real) {
    if (!gEnabled) return real;
    if (!gSteamLib) gSteamLib = handle;
    static const struct { const char *name; void *replacement; void **original; } table[] = {
        {"SteamAPI_ManualDispatch_GetNextCallback", (void *)E_GetNextCallback, (void **)&oGetNextCallback},
        {"SteamAPI_ManualDispatch_FreeLastCallback", (void *)E_FreeLastCallback, (void **)&oFreeLastCallback},
        {"SteamAPI_ManualDispatch_GetAPICallResult", (void *)E_GetAPICallResult, (void **)&oGetAPICallResult},
        {"SteamAPI_ISteamUser_GetSteamID", (void *)E_GetSteamID, (void **)&oGetSteamID},
        {"SteamAPI_ISteamFriends_GetFriendPersonaName", (void *)E_GetFriendPersonaName, (void **)&oFriendPersonaName},
        {"SteamAPI_ISteamFriends_GetLargeFriendAvatar", (void *)E_LargeAvatar, (void **)&oLargeAvatar},
        {"SteamAPI_ISteamFriends_GetMediumFriendAvatar", (void *)E_MediumAvatar, (void **)&oMediumAvatar},
        {"SteamAPI_ISteamFriends_GetSmallFriendAvatar", (void *)E_SmallAvatar, (void **)&oSmallAvatar},
        {"SteamAPI_ISteamMatchmaking_CreateLobby", (void *)E_CreateLobby, NULL},
        {"SteamAPI_ISteamMatchmaking_JoinLobby", (void *)E_JoinLobby, NULL},
        {"SteamAPI_ISteamMatchmaking_LeaveLobby", (void *)E_LeaveLobby, NULL},
        {"SteamAPI_ISteamMatchmaking_SetLobbyData", (void *)E_SetLobbyData, NULL},
        {"SteamAPI_ISteamMatchmaking_GetLobbyData", (void *)E_GetLobbyData, NULL},
        {"SteamAPI_ISteamMatchmaking_GetNumLobbyMembers", (void *)E_GetNumLobbyMembers, NULL},
        {"SteamAPI_ISteamMatchmaking_GetLobbyMemberByIndex", (void *)E_GetLobbyMemberByIndex, NULL},
        {"SteamAPI_ISteamMatchmaking_SetLobbyMemberData", (void *)E_SetLobbyMemberData, NULL},
        {"SteamAPI_ISteamMatchmaking_GetLobbyMemberData", (void *)E_GetLobbyMemberData, NULL},
        {"SteamAPI_ISteamMatchmaking_SetLobbyJoinable", (void *)E_SetLobbyJoinable, NULL},
        {"SteamAPI_ISteamMatchmaking_RequestLobbyData", (void *)E_RequestLobbyData, NULL},
        {"SteamAPI_ISteamMatchmaking_GetLobbyOwner", (void *)E_GetLobbyOwner, NULL},
        {"SteamAPI_ISteamMatchmaking_RequestLobbyList", (void *)E_RequestLobbyList, NULL},
        {"SteamAPI_ISteamNetworkingMessages_SendMessageToUser", (void *)E_SendMessageToUser, NULL},
        {"SteamAPI_ISteamNetworkingMessages_ReceiveMessagesOnChannel", (void *)E_ReceiveMessagesOnChannel, NULL},
        {"SteamAPI_ISteamNetworkingMessages_AcceptSessionWithUser", (void *)E_AcceptSession, NULL},
        {"SteamAPI_ISteamNetworkingMessages_CloseChannelWithUser", (void *)E_CloseChannel, NULL},
        {"SteamAPI_ISteamNetworkingMessages_CloseSessionWithUser", (void *)E_CloseSession, NULL},
        {"SteamAPI_SteamNetworkingMessage_t_Release", (void *)E_MessageRelease, (void **)&oMessageRelease},
        {"SteamAPI_ISteamMatchmaking_GetLobbyByIndex", (void *)E_GetLobbyByIndex, NULL},
        {"SteamAPI_ISteamMatchmaking_SetLobbyType", (void *)E_SetLobbyType, NULL},
        {"SteamAPI_ISteamMatchmaking_SetLobbyMemberLimit", (void *)E_SetLobbyMemberLimit, NULL},
        {"SteamAPI_ISteamNetworking_SendP2PPacket", (void *)E_SendP2PPacket, (void **)&oSendP2PPacket},
        {"SteamAPI_ISteamNetworking_IsP2PPacketAvailable", (void *)E_IsP2PPacketAvailable, (void **)&oIsP2PPacketAvailable},
        {"SteamAPI_ISteamNetworking_ReadP2PPacket", (void *)E_ReadP2PPacket, (void **)&oReadP2PPacket},
        {"SteamAPI_ISteamNetworking_AcceptP2PSessionWithUser", (void *)E_AcceptP2PSession, (void **)&oAcceptP2PSession},
        {"SteamAPI_ISteamNetworking_CloseP2PSessionWithUser", (void *)E_CloseP2PSession, (void **)&oCloseP2PSession},
        {"SteamAPI_ISteamNetworking_CloseP2PChannelWithUser", (void *)E_CloseP2PChannel, (void **)&oCloseP2PChannel},
        {"SteamAPI_ISteamNetworking_GetP2PSessionState", (void *)E_GetP2PSessionState, (void **)&oGetP2PSessionState},
        {"SteamAPI_RegisterCallback", (void *)E_RegisterCallback, (void **)&oRegisterCallback},
        {"SteamAPI_UnregisterCallback", (void *)E_UnregisterCallback, (void **)&oUnregisterCallback},
        {"SteamAPI_RegisterCallResult", (void *)E_RegisterCallResult, (void **)&oRegisterCallResult},
        {"SteamAPI_UnregisterCallResult", (void *)E_UnregisterCallResult, (void **)&oUnregisterCallResult},
        {"SteamAPI_RunCallbacks", (void *)E_RunCallbacks, (void **)&oRunCallbacks},
    };
    for (size_t i = 0; i < sizeof table / sizeof table[0]; i++) {
        if (strcmp(symbol, table[i].name) != 0) continue;
        if (table[i].original) *table[i].original = real;
        if (table[i].replacement == (void *)E_GetNextCallback) gManualDispatch = YES;
        EmuLog(@"emulating %s", symbol);
        return table[i].replacement;
    }
    return real;
}
