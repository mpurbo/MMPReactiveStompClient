# MMPReactiveStompClient

[![Version](https://img.shields.io/cocoapods/v/MMPReactiveStompClient.svg?style=flat)](http://cocoadocs.org/docsets/MMPReactiveStompClient)
[![License](https://img.shields.io/cocoapods/l/MMPReactiveStompClient.svg?style=flat)](http://cocoadocs.org/docsets/MMPReactiveStompClient)
[![Platform](https://img.shields.io/cocoapods/p/MMPReactiveStompClient.svg?style=flat)](http://cocoadocs.org/docsets/MMPReactiveStompClient)

MMPReactiveStompClient is a reactive WebSocket/STOMP client library based on [ReactiveCocoa](https://github.com/ReactiveCocoa/ReactiveCocoa) and [SocketRocket](https://github.com/square/SocketRocket). STOMP implementation is based on [StompKit](https://github.com/mobile-web-messaging/StompKit/). 

This is a very early version and currently only supports signals for raw WebSocket, raw STOMP frame and message, and basic STOMP subscription.

## Installation

MMPReactiveStompClient is available through [CocoaPods](http://cocoapods.org), to install
it simply add the following line to your Podfile:

    pod "MMPReactiveStompClient"

## Usage

Following code shows how to subscribe to raw WebSocket signals:
```objc
#import "MMPReactiveStompClient.h"
#import <SocketRocket/SRWebSocket.h>
#import <ReactiveCocoa/ReactiveCocoa.h>

// connecting to a WebSocket server
stompClient = [[MMPReactiveStompClient alloc] initWithURL:[NSURL URLWithString:@"ws://localhost:8080/stream/connect"]];

// opening the STOMP client returns a raw WebSocket signal that you can subscribe to
[[stompClient open]
    subscribeNext:^(id x) {
        if ([x class] == [SRWebSocket class]) {
            // First time connected to WebSocket, receiving SRWebSocket object
            NSLog(@"web socket connected with: %@", x);            
        } else if ([x isKindOfClass:[NSString class]]) {
            // Subsequent signals should be NSString
        }
    }
    error:^(NSError *error) {
        NSLog(@"web socket failed: %@", error);
    }
    completed:^{
        NSLog(@"web socket closed");
    }];
```

Following samples shows how to get STOMP frames, messages, and subscribe to a specific channel:
```objc
// subscribe to raw STOMP frames
[[_stompClient stompFrames]
    subscribeNext:^(MMPStompFrame *frame) {
        NSLog(@"STOMP frame received: command = %@", frame.command);
    }];

// subscribe to any STOMP messages
[[stompClient stompMessages]
    subscribeNext:^(MMPStompMessage *message) {
        NSLog(@"STOMP message received: body = %@", message.body);
    }];

// subscribe to a STOMP destination
[[stompClient stompMessagesFromDestination:@"/topic/test"]
    subscribeNext:^(MMPStompMessage *message) {
        NSLog(@"STOMP message received: body = %@", message.body);
    }];
```

## Settings

You can chain-call settings method after initializing to specify custom settings. Following sections explain available settings.

### SockJS

When using SockJS server, use `useSockJs` as shown below:
```objc
MMPReactiveStompClient *stompClient = [[[MMPReactiveStompClient alloc]
                                                                initWithURL:[NSURL URLWithString:@"ws://localhost:8080/stream/connect"]]
                                                                useSockJs];
```

### Custom STOMP Subscription ID 

By default each subscription to any STOMP destination will be given an ID with the following pattern:
```
sub-[running_number]
```
where `[running_number]` is automatically incremented number that starts from `0`. If you need to generate a custom ID, you can implement `MMPStompSubscriptionIdGenerator` protocol and pass the class to `subscriptionIdGenerator` method as shown in the following example:
```objc
// class implementing MMPStompSubscriptionIdGenerator protocol

@interface GeocoreStompSubscriptionIdGenerator : NSObject<MMPStompSubscriptionIdGenerator>

@property (nonatomic, assign) NSUInteger counter;

@end

@implementation GeocoreStompSubscriptionIdGenerator

// implement method for generating next ID for new subscription
- (NSString *)generateId {
    return [NSString stringWithFormat:@"mycustomsubid-%lu", (unsigned long)++_counter];
}

@end
```

## Author

Mamad Purbo, m.purbo@gmail.com

## License

MMPReactiveStompClient is available under the MIT license. See the LICENSE file for more info.

