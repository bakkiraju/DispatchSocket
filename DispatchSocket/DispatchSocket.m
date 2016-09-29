#import "DispatchSocket.h"
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

#define MTU_SIZE 1024*1024

#define CHECK(call) Check(call, __FILE__, __LINE__, #call)


static int setnonblock(int fd)
{
    int flags;
    
    flags = fcntl(fd, F_GETFL);
    if (flags < 0)
        return flags;
    flags |= O_NONBLOCK;
    if (fcntl(fd, F_SETFL, flags) < 0)
        return -1;
    
    return 0;
}

static int Check(int retval, const char *file, int line, const char *name)
{
    if(retval == -1)
    {
        fprintf(stderr, "%s:%d: %s returned error %d (%s)\n", file, line, name, errno, strerror(errno));
        exit(1);
    }
    return retval;
}

static dispatch_source_t socketSource(int s, dispatch_source_type_t type, dispatch_queue_t q, dispatch_block_t block)
{
    dispatch_source_t source = dispatch_source_create(type, s, 0, q);
    dispatch_source_set_event_handler(source, block);
    return source;
}


@interface DispatchSocket()
{
    dispatch_source_t read_source;
    dispatch_io_t reader_io_channel;
    dispatch_io_t writer_io_channel;
    dispatch_io_t file_writer_channel;
    
    bool isListening;
    bool isServer;

    //Raw Socket
    dispatch_fd_t socket4fd;
    dispatch_fd_t socket6fd;
}

@property (strong) dispatch_queue_t writerQ;
@property (strong) dispatch_queue_t readerQ,  serialQ;
@property (strong, nonatomic) id framedMessage;
@property (strong, nonatomic) NSDictionary *currentMessage;


@end

@implementation DispatchSocket

-(NSData *) frameMessageContainingData:(NSData *)dataBytes andFlags:(int) flags
{
    CFHTTPMessageRef response = CFHTTPMessageCreateResponse(kCFAllocatorDefault, 200, NULL, kCFHTTPVersion1_1);
    
    CFHTTPMessageSetHeaderFieldValue(response, (__bridge CFStringRef)@"Content-Length", (__bridge CFStringRef)[NSString stringWithFormat:@"%ld", (unsigned long)[dataBytes length]]);
    
    CFHTTPMessageSetBody(response, (__bridge CFDataRef)dataBytes);
    
    CFDataRef msgData = CFHTTPMessageCopySerializedMessage(response);
    
    NSData* messageData = [NSData dataWithData:(NSData *)CFBridgingRelease(msgData)];
    
    if (response)
       CFRelease(response);
    
    return messageData;
}

-(NSString *) printSocketInfo
{
    return [NSString stringWithFormat:@"Socket fd:%d name:%@ numOfMessages:%lu, isConnected:%d",self->socket4fd,self.name,self.numOfMessages,self.isConnected];
}

-(void) readData:(dispatch_data_t) data_to_be_read forSocket:(DispatchSocket *)socket
{
    if (data_to_be_read && dispatch_data_get_size(data_to_be_read) != 0) {
        if (!socket.framedMessage) {
            socket.framedMessage = CFBridgingRelease(CFHTTPMessageCreateEmpty(kCFAllocatorDefault, false));
        }
        
        void const *bytes = NULL; size_t bytesLength = 0;
        dispatch_data_t contiguousData __attribute__((unused, objc_precise_lifetime)) = dispatch_data_create_map(data_to_be_read, &bytes, &bytesLength);
        
        CFHTTPMessageAppendBytes((__bridge CFHTTPMessageRef)(socket.framedMessage), bytes, (CFIndex)bytesLength);
    }
    
    if (socket.framedMessage && CFHTTPMessageIsHeaderComplete((__bridge CFHTTPMessageRef)(socket.framedMessage))) {
        NSInteger contentLength = [CFBridgingRelease(CFHTTPMessageCopyHeaderFieldValue((__bridge CFHTTPMessageRef)(socket.framedMessage), CFSTR("Content-Length"))) integerValue];
        NSInteger bodyLength = (NSInteger)[CFBridgingRelease(CFHTTPMessageCopyBody((__bridge CFHTTPMessageRef)(socket.framedMessage))) length];
        
        
        if (contentLength == bodyLength) {
            NSError *error = nil;
            
            NSData *bodyData = CFBridgingRelease(CFHTTPMessageCopyBody((__bridge CFHTTPMessageRef)(socket.framedMessage)));
            
            NSPropertyListFormat format;
            
            NSDictionary *incoming_msg = [NSPropertyListSerialization propertyListWithData:bodyData options:NSPropertyListImmutable format:&format error:&error];
            
            socket.currentMessage = incoming_msg;
            
            socket.framedMessage = nil;
        } else if (contentLength < bodyLength){
            NSError *error = nil;
            
            NSLog(@"More than one response coalesced into single buffer");
            
            NSUInteger chunksize=0;
            NSData *restOfData = nil;
            do {
                NSData *bodyData = CFBridgingRelease(CFHTTPMessageCopyBody((__bridge CFHTTPMessageRef)(socket.framedMessage)));
                
                
                if ([bodyData length] > contentLength) {
                    chunksize = contentLength;
                } else {
                    chunksize = [bodyData length];
                }
                
                //extract out the payload
                //NSData* chunk = [NSData dataWithBytesNoCopy:(char *)[bodyData bytes]
                //                                     length:chunksize
                //                               freeWhenDone:NO];
                
                //NSPropertyListFormat format;
                
                //NSDictionary *incoming_msg = [NSPropertyListSerialization propertyListWithData:chunk options:NSPropertyListImmutable format:&format error:&error];
                
                
                // reset socket.framedMessage to new chunk of bytes
                id framedMessage = CFBridgingRelease(CFHTTPMessageCreateEmpty(kCFAllocatorDefault, false));
                
                NSUInteger remainingLength = 0;
                
                if ([bodyData length]  > chunksize) {
                    remainingLength = [bodyData length]-chunksize;
                } else {
                    remainingLength = [bodyData length];
                }
                
                restOfData = [NSData dataWithBytes:(char *)[bodyData bytes]+chunksize
                                                    length:remainingLength];
            
                CFHTTPMessageAppendBytes((__bridge CFHTTPMessageRef)(framedMessage), [restOfData bytes], (CFIndex)[restOfData length]);
                    
                socket.framedMessage = framedMessage;
            } while ([restOfData length] >= contentLength);
            
            NSLog(@"Coalesing done");
        } else {
            NSLog(@"Got %ld bytes, content-length of the packet: %ld",(long)bodyLength,(long)contentLength);
        }
    }
}

-(void) startReceivingMessages
{
    __weak DispatchSocket *weakSelf = self;
    
    dispatch_io_read(reader_io_channel,0, SIZE_MAX, _readerQ, ^(bool read_done, dispatch_data_t read_data, int read_error) {
        if (read_error && read_error != ECANCELED) {
            fprintf(stderr,"Error %d while reading from socket %d\n", read_error, socket4fd);
            self.isConnected = false;
            return;
        }
        
        if (!read_done)
        {
            [weakSelf readData:read_data forSocket:self];
            
            if (weakSelf.currentMessage != nil) {
                weakSelf.numOfMessages++;
                
                if([weakSelf.delegate conformsToProtocol:@protocol(DispatchSocketDelegate)]){
                    [weakSelf.delegate messageHandler:self.currentMessage onEndPoint:self];
                } else {
                // modified_bytes = @{@"Error code":@"-1",@"Error Msg":@"Doesnt implement the delegate"};
                fprintf(stderr,"Right delegate not defined to  handle messages coming on server socket %d\n", socket4fd);
                }
            
            // reset the currentMessage to nil
            weakSelf.currentMessage = nil;
        } else {
                [weakSelf startReceivingMessages];
            }
        }
        
        if (read_error) {
            // other end has closed socket, do clean up
            // _isConnected = false;
            //fprintf(stderr,"server socket %d\n", socket4fd);
            NSLog(@"Client connected to server socket %d termianted connection ",self->socket4fd);
            [self close];
        }
    });
}


-(void) sendMessage:(NSDictionary *)msg
{
    if (self.isConnected) {
    
        __weak DispatchSocket *weakSelf = self;
        NSError *err;
        
        // even though sockopt is set to ignore sigpipe, I still keep getting it
        // Looks like write() is being used underneath and not send()
        // ignoring sigpipe explicitly
        signal(SIGPIPE, SIG_IGN);
        
        NSData *data = [NSPropertyListSerialization dataWithPropertyList:msg  format:NSPropertyListBinaryFormat_v1_0 options:0 error:&err];
        
        if (data != nil)
        {
            NSData *messageBytes = [self frameMessageContainingData:data andFlags:0];
        
            dispatch_data_t modified_data = dispatch_data_create([messageBytes bytes], [messageBytes length], dispatch_get_main_queue(),  DISPATCH_DATA_DESTRUCTOR_DEFAULT);
        
            dispatch_io_write(writer_io_channel, 0, modified_data, _writerQ, ^(bool write_done, dispatch_data_t write_data, int write_error) {
            
            if (write_done) {
            }
            
            if (write_error)
            {
                if (self.isConnected)
                {
                    NSLog(@"Error %d %s writing bytes to socket %d", write_error, strerror(write_error), socket4fd);
                    [weakSelf close];
                }
            }
            });
        
            messageBytes = nil;
        
            weakSelf.numOfMessages ++;
            // space out the writes-- shud be removed later
            [NSThread sleepForTimeInterval:0.002];
         }
    } else {
        NSLog(@"This endpoint is not connected to any other communcation endpoint");
    }
}


//NSData *DataFromDispatchData(dispatch_data_t data)
//{
//    NSMutableData *result = [NSMutableData dataWithCapacity: dispatch_data_get_size(data)];
//    dispatch_data_apply(data, ^(dispatch_data_t region, size_t offset, const void *buffer, size_t size) {
//        [result appendBytes:buffer length:size];
//        return (_Bool)true;
//    });
//    return result;
//}


-(void) handleMessageOnServerSocket:(DispatchSocket *)socket
{
    __weak DispatchSocket *weakSelf = self;
    
    dispatch_io_read(socket->reader_io_channel,0, SIZE_MAX, socket.readerQ, ^(bool done, dispatch_data_t data, int error) {
        
        if (error && error != ECANCELED) {
            NSLog(@"Error %d when reading from socket %d ", error, socket->socket4fd);
        }
        
        if (data && dispatch_data_get_size(data) != 0) {
            [weakSelf readData:data forSocket:socket];
            
            if (socket.currentMessage != nil) {
                
                NSDictionary *modified_bytes = nil;
                
                socket.numOfMessages++;
                
                if([self.delegate conformsToProtocol:@protocol(DispatchSocketDelegate)]){
                    if ([self.delegate respondsToSelector:@selector(messageHandler:onEndPoint:)]) {
                        modified_bytes = [self.delegate messageHandler:socket.currentMessage onEndPoint:socket];
                    }
                } else {
                    fprintf(stderr,"Right delegate not defined to  handle messages coming on server socket %d\n", socket->socket4fd);
                }
                
                if(modified_bytes != nil)
                {
                    [socket sendMessage:modified_bytes];
                }
                
                socket.currentMessage = nil;
            } else {
                // re-invoke the dispatch_io_read to get rest of the data
                //[socket handleMessageOnServerSocket:socket];
            }
        }
        
        if (done && (data == dispatch_data_empty)) {
            NSLog(@"Peer termianted connection on Child server socket %d spawned from Server socket %d  ",socket->socket4fd,self->socket4fd);
            [socket close];
        }
        
    });
}


-(void) acceptNewConnection:(dispatch_fd_t)fd
{
    // Accept and setup socket
    struct sockaddr addr;
    
    socklen_t addrlen = sizeof(addr);
    
    dispatch_fd_t newSock = CHECK(accept(fd, &addr, &addrlen));
    
    DispatchSocket *newEp = [self initWithDescriptor:newSock andName:self.name];
    
    self.numOfConnections++;
    
    NSLog(@"Accepted new connection on server socket %d, spawned child socket for listening to peer on %d", self->socket4fd, newSock);
    
    
    newEp->reader_io_channel = dispatch_io_create(DISPATCH_IO_STREAM, newSock, dispatch_get_global_queue(0,0), ^(int error) {
        if(error) {
            fprintf(stderr, "got an error %d trying to set up reader for socket:%d (%s)\n", error, newSock, strerror(error));
        }
    });
    
    newEp->writer_io_channel = dispatch_io_create(DISPATCH_IO_STREAM, newSock, dispatch_get_global_queue(0,0), ^(int error) {
        if(error)
            fprintf(stderr, "got an error %d trying to setup writer for socket %d (%s)\n", error, newSock, strerror(error));
    });
    
    newEp.isConnected = true;
    newEp.delegate = self.delegate;
    
    dispatch_io_set_low_water(newEp->reader_io_channel, 1);
    dispatch_io_set_high_water(newEp->reader_io_channel, SIZE_MAX);
    dispatch_io_set_low_water(newEp->writer_io_channel, 1);
    dispatch_io_set_high_water(newEp->writer_io_channel, SIZE_MAX);
    
    // start reading from accepted connection
    [self handleMessageOnServerSocket:newEp];
}


-(int) startServiceOnPort:(int)port
{
    struct sockaddr_in servaddr;
    
    __block int errorCode = NOERROR;
    
    if ((self->socket4fd = socket(AF_INET, SOCK_STREAM, 0)) < 0)
    {
        errorCode = SOCKETERROR;
        return errorCode;
    }
    
    setnonblock(self->socket4fd);
    
    int set = 1;
    
    CHECK(setsockopt(self->socket4fd, SOL_SOCKET, SO_NOSIGPIPE, (void *)&set, sizeof(set)));
    
    CHECK(setsockopt(self->socket4fd, SOL_SOCKET, SO_REUSEPORT, (const char *)&set, sizeof(set)));
    
    memset(&servaddr, 0, sizeof(servaddr));
    servaddr.sin_family = AF_UNSPEC;
    servaddr.sin_addr.s_addr = htonl(INADDR_ANY);
    servaddr.sin_port = htons(port);
    
    self->isServer = YES;
    
    if (bind(self->socket4fd, (struct sockaddr *)&servaddr, sizeof(servaddr)) <0) {
        errorCode = BINDERROR;
        return errorCode;
    }
    
    if ((listen (self->socket4fd, MAX_SOCKET_BUFF)) <0) {
        errorCode = LISTENERROR;
        return errorCode;
    }
    
    
    reader_io_channel = dispatch_io_create(DISPATCH_IO_STREAM, self->socket4fd, dispatch_get_global_queue(0,0), ^(int error) {
        if(error) {
            fprintf(stderr, "got an error %d trying to set up reader for socket:%d (%s)\n", error, socket4fd, strerror(error));
        }
    });
    
    
    read_source = socketSource(self->socket4fd, DISPATCH_SOURCE_TYPE_READ, dispatch_get_global_queue(0, 0), ^{
            [self acceptNewConnection:self->socket4fd];
    });
    
    dispatch_resume(read_source);
    
    NSLog(@"Started services at port %d with socket fd: %d",port, socket4fd);
    
    return errorCode;
}


// Returns 0 on Success
// Non zero error code on Failure to conenct

-(int) connectToServiceAt:(NSString *) ipaddr OnPort:(int)port
{
    int errorCode = NOERROR;
    
    struct sockaddr_in   servaddr;
    
    if (ipaddr == nil) {
        errorCode = CONNECTERROR;
        return errorCode;
    }
    
    if ((socket4fd = socket(AF_INET, SOCK_STREAM, 0)) < 0)
    {
        errorCode = SOCKETERROR;
    } else {
        self.isConnected = false;
        int set = 1;
        
        setsockopt(socket4fd, SOL_SOCKET, SO_NOSIGPIPE, (void *)&set, sizeof(int));
        
        memset(&servaddr,0, sizeof(servaddr));
        servaddr.sin_family = AF_INET;
        servaddr.sin_port = htons(port);
        inet_pton(AF_INET, [ipaddr cStringUsingEncoding:NSUTF8StringEncoding], &servaddr.sin_addr);
        if (connect(socket4fd, (struct sockaddr *)&servaddr,
                    sizeof(servaddr)) < 0) {
            errorCode = CONNECTERROR;
            return errorCode;
        }
        
        reader_io_channel = dispatch_io_create(DISPATCH_IO_STREAM, self->socket4fd, dispatch_get_global_queue(0,0), ^(int error) {
            if(error)
                fprintf(stderr, "got an error %d trying to set up reader for socket:%d (%s)\n", error, self->socket4fd, strerror(error));
        }); dispatch_io_set_low_water(reader_io_channel, 1); dispatch_io_set_high_water(reader_io_channel, SIZE_MAX);
        
        
        writer_io_channel = dispatch_io_create(DISPATCH_IO_STREAM, self->socket4fd, dispatch_get_global_queue(0,0), ^(int error) {
            if(error)
                fprintf(stderr, "got an error %d trying to set up writer for socket:%d (%s)\n", error, self->socket4fd, strerror(error));
        });  dispatch_io_set_low_water(writer_io_channel, 1); dispatch_io_set_high_water(writer_io_channel, SIZE_MAX);
    }
    
    if (errorCode == NOERROR) {
        self.isConnected = YES;
        [self startReceivingMessages];
    }
    
    return errorCode;
}


-(void) close
{
    NSLog(@"Cleaning up endpoint %d", self->socket4fd);
    
    if ([self.delegate conformsToProtocol:@protocol(DispatchSocketDelegate)] &&
        [self.delegate respondsToSelector:(@selector(terminationHandler:onEndPoint:))])
    {
        [self.delegate terminationHandler:@{@"MISC_INFO": @{@"COMMAND":@"DISCONNECT"}} onEndPoint:self];
    }
    
    close(socket4fd);
    
    self.isConnected = false;
    
    if (self->reader_io_channel)
    dispatch_io_close(self->reader_io_channel, DISPATCH_IO_STOP);
    
    if (self->writer_io_channel)
    dispatch_io_close(self->writer_io_channel, DISPATCH_IO_STOP);
    
    if(self->read_source)
    {
        dispatch_source_cancel(self->read_source);
    }    // isListening = false;
    
}

-(id)init
{
    if (self = [super init])
    {
        NSString *uuidString = [[NSUUID UUID] UUIDString];
        
        // NSLog(@"uuid %@",uuidString);
        
        const char *wsq_name = [[NSString stringWithFormat:@"writer.com.apple.hwte.%@",uuidString] UTF8String];
        self.writerQ =  dispatch_queue_create(wsq_name, DISPATCH_QUEUE_CONCURRENT);
        
        const char *rsq_name = [[NSString stringWithFormat:@"reader.com.apple.hwte.%@",uuidString] UTF8String];
        self.readerQ =  dispatch_queue_create(rsq_name, DISPATCH_QUEUE_CONCURRENT);
        
        self.serialQ = dispatch_queue_create([[NSString stringWithFormat:@"reader.com.apple.hwte.serial_%@",uuidString] UTF8String], DISPATCH_QUEUE_SERIAL);

        //self.msgQ = [[NSMutableArray alloc] initWithCapacity:5];
        //connections = [[NSMutableDictionary alloc] initWithCapacity:0];
        
        self.framedMessage  = nil;
        self.isConnected = false;
        self.numOfMessages = 0;
        self.numOfConnections = 0;
        self->socket4fd = -1;
        self->socket6fd = -1;
    }
    
    return self;
}

-(id) initWithName:(NSString *) socketName
{
    self = [self init];
    _name = socketName;
    return self;
}

-(id) initWithDescriptor:(dispatch_fd_t) fd andName:(NSString *)sockName
{
    DispatchSocket *ep = [[DispatchSocket alloc] init];
    ep->socket4fd = fd;
    setnonblock(self->socket4fd);

    ep.name = sockName;
    return ep;
}


@end
