//
//  MMGReactiveStompClient.h
//  GeocoreStreamTest
//
//  Created by Purbo Mohamad on 5/22/14.
//  Copyright (c) 2014 purbo.org. All rights reserved.
//

#import <Foundation/Foundation.h>

#pragma mark Frame headers

#define kHeaderAcceptVersion @"accept-version"
#define kHeaderAck           @"ack"
#define kHeaderContentLength @"content-length"
#define kHeaderDestination   @"destination"
#define kHeaderHeartBeat     @"heart-beat"
#define kHeaderHost          @"host"
#define kHeaderID            @"id"
#define kHeaderLogin         @"login"
#define kHeaderMessage       @"message"
#define kHeaderPasscode      @"passcode"
#define kHeaderReceipt       @"receipt"
#define kHeaderReceiptID     @"receipt-id"
#define kHeaderSession       @"session"
#define kHeaderSubscription  @"subscription"
#define kHeaderTransaction   @"transaction"

#pragma mark Ack Header Values

#define kAckAuto             @"auto"
#define kAckClient           @"client"
#define kAckClientIndividual @"client-individual"

@class SRWebSocket;
@class RACSignal;

@interface MMPStompFrame : NSObject

@property (nonatomic, copy, readonly) NSString *command;
@property (nonatomic, copy, readonly) NSDictionary *headers;
@property (nonatomic, copy, readonly) NSString *body;

@end

@interface MMPStompMessage : MMPStompFrame

- (void)ack;
- (void)ack:(NSDictionary *)headers;
- (void)nack;
- (void)nack:(NSDictionary *)headers;

@end

@interface MMPStompSubscription : NSObject

@property (nonatomic, copy, readonly) NSString *identifier;

@end

/**
 *  Reactive STOMP client based on ReactiveCocoa and SocketRocket.
 */
@interface MMPReactiveStompClient : NSObject

/** @name Creating */

- (id)initWithURL:(NSURL *)url;
- (id)initWithURLRequest:(NSURLRequest *)urlRequest;
- (id)initWithSocket:(SRWebSocket *)socket;

/** @name Opening and Closing */

- (RACSignal *)open;
- (void)close;

/** @name Settings */

- (instancetype)useSockJs;

/** @name Signals */

/**
 *  Signal for subscribing to raw web socket data frames.
 *
 *  @return raw web socket signal.
 */
- (RACSignal *)webSocketData;

/**
 *  Signal for subscribing to all STOMP frames.
 *
 *  @return STOMP frame signal.
 */
- (RACSignal *)stompFrames;

/**
 *  Signal for subscribing to all STOMP messages.
 *
 *  @return STOMP message signal.
 */
- (RACSignal *)stompMessages;

/**
 *  Signal for subscribing to all STOMP messages coming from the specified subscription destination.
 *
 *  @param destination STOMP subscription destination
 *
 *  @return STOMP message signal coming from the specified destination.
 */
- (RACSignal *)stompMessagesFromDestination:(NSString *)destination;

- (void)connectWithHeaders:(NSDictionary *)headers;
- (void)sendMessage:(NSString *)message toDestination:(NSString *)destination;
- (void)sendFrameWithCommand:(NSString *)command
                     headers:(NSDictionary *)headers
                        body:(NSString *)body;

@end
