# DispatchSocket


#Creation of server and client sockets: 

 DispatchSocket *server_ep = [[DispatchSocket alloc] initWithName:@"server"];

 DispatchSocket *client_ep[MAX_CLIENTS];

        for(int i=0;i<MAX_CLIENTS;i++) {
            client_ep[i] = [[DispatchSocket alloc] initWithName:[NSString stringWithFormat:@"client%d",i+1]];
        }



#Delegate for handling messages:

- Creates a class that implements DispatchSocketDelegate

@interface ServerHandler<DispatchSocketDelegate>

@end

@implementation
-(NSDictionary *) messageHandler:(NSDictionary *)msg onEndPoint:(DispatchSocket *)ep
{
}
@end

- Assign it to server socket's delegate
server_ep.delegate = [[ServerHandler alloc] init];


        
# Start service on server endpoint:

[server_ep startServiceOnPort:SERVER_PORT];
        
# Connect clients to server
   for(int i=0; i < MAX_CLIENTS; i++)
   [client_ep[i] connectToServiceAt:@"127.0.0.1" OnPort:SERVER_PORT];

# send messages
        for (int i=0 ; i < MAX_CLIENTS; i++) {
            for (int j=0; j < MAX_PACKETS; j++) {
                [client_ep[i] sendMessage:@{@"KEY1":@"HELLO"}];
            }
        }
        
# close and clean up
   for (int i=0; i < MAX_CLIENTS; i++)
       [client_ep[i] close];
        
   [server_ep close];
   
