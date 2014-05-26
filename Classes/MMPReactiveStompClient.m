//
//  MMGReactiveStompClient.m
//  GeocoreStreamTest
//
//  Created by Purbo Mohamad on 5/22/14.
//  Copyright (c) 2014 purbo.org. All rights reserved.
//

#import "MMPReactiveStompClient.h"
#import <SocketRocket/SRWebSocket.h>
#import <ReactiveCocoa/ReactiveCocoa.h>
#import <ReactiveCocoa/RACEXTScope.h>
#import <objc/runtime.h>

#ifdef DEBUG
#   define MMPRxSC_LOG(fmt, ...) NSLog((@"%s [Line %d] " fmt), __PRETTY_FUNCTION__, __LINE__, ##__VA_ARGS__);
#else
#   define MMPRxSC_LOG(...)
#endif

#pragma mark Frame commands

#define kCommandAbort       @"ABORT"
#define kCommandAck         @"ACK"
#define kCommandBegin       @"BEGIN"
#define kCommandCommit      @"COMMIT"
#define kCommandConnect     @"CONNECT"
#define kCommandConnected   @"CONNECTED"
#define kCommandDisconnect  @"DISCONNECT"
#define kCommandError       @"ERROR"
#define kCommandMessage     @"MESSAGE"
#define kCommandNack        @"NACK"
#define kCommandReceipt     @"RECEIPT"
#define kCommandSend        @"SEND"
#define kCommandSubscribe   @"SUBSCRIBE"
#define kCommandUnsubscribe @"UNSUBSCRIBE"

#pragma mark Control characters

#define	kLineFeed @"\x0A"
#define	kNullChar @"\x00"
#define kHeaderSeparator @":"

#pragma mark - STOMP objects' privates

@interface MMPStompFrame()

- (id)initWithCommand:(NSString *)command
              headers:(NSDictionary *)headers
                 body:(NSString *)body;

- (NSString *)toString;
+ (MMPStompFrame *)fromString:(NSString *)string;

@end

@interface MMPStompMessage()

@property (nonatomic, strong) MMPReactiveStompClient *client;

- (id)initWithClient:(MMPReactiveStompClient *)client
             headers:(NSDictionary *)headers
                body:(NSString *)body;

+ (MMPStompMessage *)fromFrame:(MMPStompFrame *)frame
                        client:(MMPReactiveStompClient *)client;

@end

@interface MMPStompSubscription()

@property (nonatomic, strong) MMPReactiveStompClient *client;

- (id)initWithClient:(MMPReactiveStompClient *)client
          identifier:(NSString *)identifier;
- (void)unsubscribe;

@end

@interface MMPStompSubscriptionMetadata : NSObject

@property (nonatomic, strong) MMPStompSubscription *subscription;
@property (nonatomic, strong) RACSignal *signal;

@end

#pragma mark - STOMP client's privates

@interface MMPReactiveStompClient()<SRWebSocketDelegate> {
    int idGenerator;
}

@property (nonatomic, strong) SRWebSocket *socket;
@property (nonatomic, strong) RACSubject *socketSubject;

// multicast for each destination
@property (nonatomic, strong) NSMutableDictionary *subscriptions;

@end

#pragma mark - STOMP client's privates

@implementation MMPReactiveStompClient

- (id)initWithURL:(NSURL *)url
{
    if (self = [super init]) {
        self.socket = [[SRWebSocket alloc] initWithURL:url];
        _socket.delegate = self;
        self.socketSubject = nil;
    }
    return self;
}

- (RACSignal *)open
{
    self.subscriptions = [NSMutableDictionary dictionary];
    self.socketSubject = [RACSubject subject];
    idGenerator = 0;
    [_socket open];
    return _socketSubject;
}

- (void)close
{
    [_socket close];
}

- (RACSignal *)webSocketData
{
    return _socketSubject;
}

- (RACSignal *)stompFrames
{
    return [[_socketSubject
             filter:^BOOL(id value) {
                 // web socket "connected" event emits SRWebSocket object
                 // but we only interested in NSString so that it can be mapped
                 // into a MMPStompFrame
                 return [value isKindOfClass:[NSString class]];
             }]
             map:^id(id value) {
                 return [MMPStompFrame fromString:value];
             }];
}

- (RACSignal *)stompMessages
{
    @weakify(self)
    
    return [[[self stompFrames]
              filter:^BOOL(MMPStompFrame *frame) {
                  // only interested in STOMP "MESSAGE" frame
                  return [kCommandMessage isEqualToString:frame.command];
              }]
              map:^id(MMPStompFrame *frame) {
                  @strongify(self)
                  return [MMPStompMessage fromFrame:frame client:self];
              }];
}

- (RACSignal *)stompMessagesFromDestination:(NSString *)destination
{
    MMPStompSubscriptionMetadata *subscription = nil;
    
    // only 1 subscription (multicast) signal per destination
    @synchronized(_subscriptions) {
        subscription = [_subscriptions objectForKey:destination];
        if (!subscription) {
            
            subscription = [[MMPStompSubscriptionMetadata alloc] init];
            
            @weakify(self)
            
            // create signal as multicast so the side-effect is only executed once
            RACMulticastConnection *mc = [[RACSignal createSignal:^RACDisposable *(id<RACSubscriber> subscriber) {
                
                @strongify(self)
                
                MMPRxSC_LOG(@"Subscribing to STOMP destination: %@", destination)
                subscription.subscription = [self subscribeTo:destination headers:nil];
                
                [[[self stompMessages]
                   // filter messages by destination
                   filter:^BOOL(MMPStompMessage *message) {
                       return [destination isEqualToString:[message.headers objectForKey:kHeaderDestination]];
                   }]
                   // basically just pass along all signals
                   subscribe:subscriber];
                
                return [RACDisposable disposableWithBlock:^{
                    
                }];
                
            }] publish];
            [mc connect];
            
            subscription.signal = mc.signal;
            [_subscriptions setObject:subscription forKey:destination];

        } else {
            MMPRxSC_LOG(@"Previously subscribed to STOMP destination: %@, reusing signal.", destination)
        }
    }
    
    return subscription.signal;
}

#pragma mark Low-level STOMP operations

- (void)sendFrameWithCommand:(NSString *)command
                     headers:(NSDictionary *)headers
                        body:(NSString *)body
{
    if (!_socketSubject || _socket.readyState != SR_OPEN) {
        // invalid socket state
        NSLog(@"[ERROR] Socket is not opened");
        return;
    }
    
    MMPStompFrame *frame = [[MMPStompFrame alloc] initWithCommand:command headers:headers body:body];
    MMPRxSC_LOG(@"Sending frame %@", frame)
    [_socket send:[frame toString]];
}

- (MMPStompSubscription *)subscribeTo:(NSString *)destination
            headers:(NSDictionary *)headers
{
    NSMutableDictionary *subHeaders = [[NSMutableDictionary alloc] initWithDictionary:headers];
    subHeaders[kHeaderDestination] = destination;
    NSString *identifier = subHeaders[kHeaderID];
    if (!identifier) {
        identifier = [NSString stringWithFormat:@"sub-%d", idGenerator++];
        subHeaders[kHeaderID] = identifier;
    }
    [self sendFrameWithCommand:kCommandSubscribe
                       headers:subHeaders
                          body:nil];
    return [[MMPStompSubscription alloc] initWithClient:self identifier:identifier];
}

#pragma mark SRWebSocketDelegate implementation

- (void)webSocket:(SRWebSocket *)webSocket didReceiveMessage:(id)message
{
    MMPRxSC_LOG(@"received message: %@", message)
    [_socketSubject sendNext:message];
}

- (void)webSocketDidOpen:(SRWebSocket *)webSocket
{
    MMPRxSC_LOG(@"web socket opened")
    [_socketSubject sendNext:webSocket];
}

- (void)webSocket:(SRWebSocket *)webSocket didFailWithError:(NSError *)error
{
    MMPRxSC_LOG(@"web socket failed: %@", error)
    [_socketSubject sendError:error];
    self.socketSubject = nil;
}

- (void)webSocket:(SRWebSocket *)webSocket didCloseWithCode:(NSInteger)code reason:(NSString *)reason wasClean:(BOOL)wasClean
{
    MMPRxSC_LOG(@"web socket closed: code = %ld, reason = %@, clean ? %@", (long)code, reason, wasClean ? @"YES" : @"NO")
    [_socketSubject sendCompleted];
    self.socketSubject = nil;
}

@end

#pragma mark - MMPStompFrame implementation

@implementation MMPStompFrame

- (id)initWithCommand:(NSString *)command
              headers:(NSDictionary *)headers
                 body:(NSString *)body
{
    if (self = [super init]) {
        _command = command;
        _headers = headers;
        _body = body;
    }
    return self;
}

- (NSString *)toString
{
    NSMutableString *frame = [NSMutableString stringWithString: [self.command stringByAppendingString:kLineFeed]];
	for (id key in self.headers) {
        [frame appendString:[NSString stringWithFormat:@"%@%@%@%@", key, kHeaderSeparator, self.headers[key], kLineFeed]];
	}
    [frame appendString:kLineFeed];
	if (self.body) {
		[frame appendString:self.body];
	}
    [frame appendString:kNullChar];
    return frame;
}

+ (MMPStompFrame *)fromString:(NSString *)string
{
    NSMutableArray *contents = (NSMutableArray *)[[string componentsSeparatedByString:kLineFeed] mutableCopy];
    while ([contents count] > 0 && [contents[0] isEqual:@""]) {
        [contents removeObjectAtIndex:0];
    }
	NSString *command = [[contents objectAtIndex:0] copy];
	NSMutableDictionary *headers = [[NSMutableDictionary alloc] init];
	NSMutableString *body = [[NSMutableString alloc] init];
	BOOL hasHeaders = NO;
    [contents removeObjectAtIndex:0];
	for(NSString *line in contents) {
		if(hasHeaders) {
            for (int i=0; i < [line length]; i++) {
                unichar c = [line characterAtIndex:i];
                if (c != '\x00') {
                    [body appendString:[NSString stringWithFormat:@"%c", c]];
                }
            }
		} else {
			if ([line isEqual:@""]) {
				hasHeaders = YES;
			} else {
				NSMutableArray *parts = [NSMutableArray arrayWithArray:[line componentsSeparatedByString:kHeaderSeparator]];
				// key ist the first part
				NSString *key = parts[0];
                [parts removeObjectAtIndex:0];
                headers[key] = [parts componentsJoinedByString:kHeaderSeparator];
			}
		}
	}
    return [[MMPStompFrame alloc] initWithCommand:command headers:headers body:body];
}

@end

#pragma mark - MMPStompSubscription implementation

@implementation MMPStompMessage

- (id)initWithClient:(MMPReactiveStompClient *)client
             headers:(NSDictionary *)headers
                body:(NSString *)body
{
    if (self = [super initWithCommand:kCommandMessage
                              headers:headers
                                 body:body]) {
        self.client = client;
    }
    return self;
}

+ (MMPStompMessage *)fromFrame:(MMPStompFrame *)frame
                        client:(MMPReactiveStompClient *)client
{
    return [[MMPStompMessage alloc] initWithClient:client
                                           headers:frame.headers
                                              body:frame.body];
}

- (void)ack
{
    [self ackWithCommand:kCommandAck headers:nil];
}

- (void)ack: (NSDictionary *)headers
{
    [self ackWithCommand:kCommandAck headers:headers];
}

- (void)nack
{
    [self ackWithCommand:kCommandNack headers:nil];
}

- (void)nack: (NSDictionary *)headers
{
    [self ackWithCommand:kCommandNack headers:headers];
}

- (void)ackWithCommand:(NSString *)command
               headers:(NSDictionary *)headers
{
    NSMutableDictionary *ackHeaders = [[NSMutableDictionary alloc] initWithDictionary:headers];
    ackHeaders[kHeaderID] = self.headers[kHeaderAck];
    [self.client sendFrameWithCommand:command
                              headers:ackHeaders
                                 body:nil];
}

@end

#pragma mark - MMPStompSubscription implementation

@implementation MMPStompSubscription

- (id)initWithClient:(MMPReactiveStompClient *)client
          identifier:(NSString *)identifier
{
    if(self = [super init]) {
        _client = client;
        _identifier = [identifier copy];
    }
    return self;
}

- (void)unsubscribe {
    [self.client sendFrameWithCommand:kCommandUnsubscribe
                              headers:@{kHeaderID: self.identifier}
                                 body:nil];
}

@end

@implementation MMPStompSubscriptionMetadata



@end

