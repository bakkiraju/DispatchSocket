#import <Foundation/Foundation.h>

#define MAX_SOCKET_BUFF 1024

#define kDELAY 0.1

typedef NS_ENUM(NSUInteger, BSDErrorCode) {
    NOERROR,
    SOCKETERROR,
    BINDERROR,
    LISTENERROR,
    ACCEPTINGERROR,
    CFSOCKETCREATEERROR,
    CONNECTERROR
};

typedef NS_ENUM(NSUInteger, SocketType) {
    RAWSOCKET,
    STREAM,
};

@class DispatchSocket;

typedef NSDictionary *(^serviceBlock)(NSDictionary *, DispatchSocket *);

@protocol DispatchSocketDelegate <NSObject>

@required
-(NSDictionary *) messageHandler:(NSDictionary *)msg onEndPoint:(DispatchSocket *)ep;

@optional
// Executed when the connection to the peer of this end point terminates
-(NSDictionary *) terminationHandler:(NSDictionary *)msg onEndPoint:(DispatchSocket *)ep;
// Executed when the connection to the peer of this end point is established
-(NSDictionary *) connectionHandler:(NSDictionary *)msg onEndPoint:(DispatchSocket *)ep;

@end


@interface DispatchSocket:NSObject<NSStreamDelegate>

@property (strong) id<DispatchSocketDelegate> delegate;

@property BOOL isConnected;

@property unsigned long numOfMessages;

@property unsigned long  numOfConnections;

@property NSString *name;

// initializers
-(id) initWithName:(NSString *)name;

/* Print the socket discription */
-(NSString *) printSocketInfo;

/* Connect to a service on local machine on a given port */
-(int) startServiceOnPort:(int)port;

/* Connect to a service at an ip:port */
-(int) connectToServiceAt:(NSString *) ipaddr OnPort:(int)port;

/*send the message to service you are conencted to */
-(void) sendMessage:(NSDictionary *)msg;

/* close the end point and clean up */
-(void) close;


@end