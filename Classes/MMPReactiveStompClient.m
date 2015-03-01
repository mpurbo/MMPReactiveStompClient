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
- (NSString *)toSockString;
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
@property (nonatomic, assign) NSUInteger subscribers;

- (id)initWithClient:(MMPReactiveStompClient *)client
          identifier:(NSString *)identifier;
- (void)unsubscribe;

@end

#pragma mark - STOMP client's privates

@interface MMPReactiveStompClient()<SRWebSocketDelegate> {
    int idGenerator;
}

@property (nonatomic, strong) SRWebSocket *socket;
@property (atomic, strong) RACSubject *socketSubject;

@property (nonatomic, assign) BOOL useSockJsFlag;

// MMPStompSubscription object for each destination
@property (nonatomic, strong) NSMutableDictionary *subscriptions;

@end

#pragma mark - STOMP client's privates

@implementation MMPReactiveStompClient

- (id)initWithURL:(NSURL *)url {
    return [self initWithSocket:[[SRWebSocket alloc] initWithURL:url]];
}

- (id)initWithURLRequest:(NSURLRequest *)urlRequest {
    return [self initWithSocket:[[SRWebSocket alloc] initWithURLRequest:urlRequest]];
}

- (id)initWithSocket:(SRWebSocket *)socket {
    if (self = [super init]) {
        self.socket = socket;
        _socket.delegate = self;
        self.socketSubject = nil;
        self.useSockJsFlag = NO;
    }
    return self;
}

- (RACSignal *)open
{
    self.subscriptions = [NSMutableDictionary dictionary];
    self.socketSubject = [RACSubject subject];
    idGenerator = 0;
    [_socket open];
    return self.socketSubject;
}

- (void)close {
    [_socket close];
}

- (instancetype)useSockJs {
    self.useSockJsFlag = YES;
    return self;
}

- (RACSignal *)webSocketData
{
    return self.socketSubject;
}

- (RACSignal *)stompFrames
{
    return [[self.socketSubject
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
    @weakify(self)
    
    return [RACSignal
        createSignal:^RACDisposable *(id<RACSubscriber> subscriber) {
            
            @strongify(self)
            
            // subscribe to STOMP destination if necessary
            @synchronized(_subscriptions) {
                MMPStompSubscription *subscription = [_subscriptions objectForKey:destination];
                if (!subscription) {
                    MMPRxSC_LOG(@"Subscribing to STOMP destination: %@", destination)
                    subscription = [self subscribeTo:destination headers:nil];
                    [_subscriptions setObject:subscription forKey:destination];
                } else {
                    MMPRxSC_LOG(@"%lu subscribed to STOMP destination: %@", (unsigned long)subscription.subscribers, destination)
                }
                subscription.subscribers++;
            }
            
            [[[self stompMessages]
              // filter messages by destination
              filter:^BOOL(MMPStompMessage *message) {
                  return [destination isEqualToString:[message.headers objectForKey:kHeaderDestination]];
              }]
              // basically just pass along filtered signals to subscriber
              subscribe:subscriber];
            
            return [RACDisposable disposableWithBlock:^{
                // unsubscribe from STOMP destination if there are no more subscribers
                @synchronized(_subscriptions) {
                    MMPStompSubscription *subscription = [_subscriptions objectForKey:destination];
                    if (subscription) {
                        subscription.subscribers--;
                        if (subscription.subscribers <= 0) {
                            MMPRxSC_LOG(@"Trying to unsubscribe from STOMP destination: %@", destination)
                            if ([self socketStateValid]) {
                                MMPRxSC_LOG(@"Unsubscribing STOMP destination: %@", destination)
                                [subscription unsubscribe];
                            }
                            [_subscriptions removeObjectForKey:destination];
                        } else {
                            MMPRxSC_LOG(@"%lu still subscribed to STOMP destination: %@", (unsigned long)subscription.subscribers, destination)
                        }
                    } else {
                        // shouldn't happen
                    }
                }
            }];
        }];
}

- (void)connectWithHeaders:(NSDictionary *)headers {
    [self sendFrameWithCommand:kCommandConnect
                       headers:headers
                          body:@""];

}

- (void)sendMessage:(NSString *)message toDestination:(NSString *)destination {
    [self sendFrameWithCommand:kCommandSend
                       headers:@{
                                 kHeaderDestination: destination,
                                 kHeaderContentLength: @(message.length),
                                 }
                          body:message];
}

#pragma mark Low-level STOMP operations

- (BOOL)socketStateValid
{
    return (self.socketSubject && _socket.readyState == SR_OPEN);
}

- (void)sendFrameWithCommand:(NSString *)command
                     headers:(NSDictionary *)headers
                        body:(NSString *)body
{
    if (![self socketStateValid]) {
        // invalid socket state
        NSLog(@"[ERROR] Socket is not opened");
        return;
    }
    
    MMPStompFrame *frame = [[MMPStompFrame alloc] initWithCommand:command headers:headers body:body];
    MMPRxSC_LOG(@"Sending frame %@", frame)
    NSString *data = self.useSockJsFlag ? [frame toSockString] : [frame toString];
    [_socket send:data];
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
    NSString *extractedMessage = message;
    if (self.useSockJsFlag) {
        extractedMessage = [extractedMessage stringByReplacingOccurrencesOfString:@"\\\\" withString:@"\\"];
        extractedMessage = [extractedMessage stringByReplacingOccurrencesOfString:@"\\\"" withString:@"\""];
        extractedMessage = [extractedMessage stringByReplacingOccurrencesOfString:@"\\n" withString:@"\n"];
        extractedMessage = [extractedMessage stringByReplacingOccurrencesOfString:@"a[\"" withString:@""];
        extractedMessage = [extractedMessage stringByReplacingOccurrencesOfString:@"\\u0000\"]" withString:@"\0"];
    }
    MMPRxSC_LOG(@"received message: %@", extractedMessage)
    [self.socketSubject sendNext:extractedMessage];
}

- (void)webSocketDidOpen:(SRWebSocket *)webSocket
{
    MMPRxSC_LOG(@"web socket opened")
    [self.socketSubject sendNext:webSocket];
}

- (void)webSocket:(SRWebSocket *)webSocket didFailWithError:(NSError *)error
{
    MMPRxSC_LOG(@"web socket failed: %@", error)
    [self.socketSubject sendError:error];
    self.socketSubject = nil;
}

- (void)webSocket:(SRWebSocket *)webSocket didCloseWithCode:(NSInteger)code reason:(NSString *)reason wasClean:(BOOL)wasClean
{
    MMPRxSC_LOG(@"web socket closed: code = %ld, reason = %@, clean ? %@", (long)code, reason, wasClean ? @"YES" : @"NO")
    [self.socketSubject sendCompleted];
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

-(NSString *)toSockString {
    NSString *stompString = self.toString;
    stompString = [stompString stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"];
    stompString = [stompString stringByReplacingOccurrencesOfString:@"\0" withString:@"\\u0000"];
    stompString = [stompString stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    return [NSString stringWithFormat:@"[\"%@\"]", stompString];
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
                if (c != 0x0000) {
                    [body appendString:[NSString stringWithFormat:@"%C", c]];
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
        _subscribers = 0;
    }
    return self;
}

- (void)unsubscribe {
    [self.client sendFrameWithCommand:kCommandUnsubscribe
                              headers:@{kHeaderID: self.identifier}
                                 body:nil];
}

@end

