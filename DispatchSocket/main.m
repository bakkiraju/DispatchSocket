//
//  main.m
//  DispatchSocket
//
//  Created by Bilahari Akkiraju on 9/29/16.
//  Copyright © 2016 Apple. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "DispatchSocket.h"

@interface ServerHandler : NSObject<DispatchSocketDelegate>

@end

@implementation ServerHandler

-(NSDictionary *) messageHandler:(NSDictionary *)msg onEndPoint:(DispatchSocket *)ep
{
    NSLog(@"Received %@ on %@",msg, [ep printSocketInfo]);
    return nil;
}

@end

#define MAX_CLIENTS 10
#define SERVER_PORT 8060
#define MAX_PACKETS 10
int main(int argc, const char * argv[]) {
    

    
    @autoreleasepool {
        DispatchSocket *server_ep;
        
        server_ep = [[DispatchSocket alloc] initWithName:@"server"];
        DispatchSocket *client_ep[MAX_CLIENTS];
        
        for(int i=0;i<MAX_CLIENTS;i++) {
            client_ep[i] = [[DispatchSocket alloc] initWithName:[NSString stringWithFormat:@"client%d",i+1]];
        }
        
        
        [server_ep startServiceOnPort:SERVER_PORT];
        
        server_ep.delegate = [[ServerHandler alloc] init];
        
        for(int i=0; i < MAX_CLIENTS; i++)
            [client_ep[i] connectToServiceAt:@"127.0.0.1" OnPort:SERVER_PORT];
        
        for (int i=0 ; i < MAX_CLIENTS; i++) {
            for (int j=0; j < MAX_PACKETS; j++) {
                [client_ep[i] sendMessage:@{@"KEY1":@"HELLO"}];
            }
        }
        
        int i = 0;
        
        while(1) {
            int not_done = 0;
            for (int i=0;i <MAX_CLIENTS; i++) {
                if(client_ep[i].numOfMessages == MAX_PACKETS) {
                    continue;
                } else {
                    NSLog(@"Waiting for client %d to finish",i+1);
                    [NSThread sleepForTimeInterval:1.0];
                    not_done = 1;
                }
            }
            
            if (not_done == 0) {
                break;
            }
        }
        

        for (int i=0; i < MAX_CLIENTS; i++)
            NSLog(@"Client %d received back %lu messages",i+1,[client_ep[i] numOfMessages]);

        for (int i=0; i < MAX_CLIENTS; i++)
            [client_ep[i] close];
        
        [server_ep close];
    }
    
    
    return 0;
}
