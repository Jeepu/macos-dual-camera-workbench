// UVC class controls through the device's default control pipe.
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <errno.h>
#include <limits.h>
#include <unistd.h>

typedef struct {
    const char *key;
    uint8_t terminal, selector, bit, size, signed_value;
} Control;

static const Control controls[] = {
    {"focusAuto",1,8,17,1,0}, {"focus",1,6,5,2,0},
    {"zoom",1,11,9,2,0}, {"exposureAuto",1,2,1,1,0},
    {"exposure",1,4,3,4,0}, {"brightness",0,2,0,2,1},
    {"contrast",0,3,1,2,0}, {"hue",0,6,2,2,1},
    {"saturation",0,7,3,2,0}, {"sharpness",0,8,4,2,0},
    {"gamma",0,9,5,2,0}, {"temperature",0,10,6,2,0},
    {"whiteBalanceAuto",0,11,12,1,0}, {"backlight",0,1,8,2,0},
    {"gain",0,4,9,2,0}, {"powerLine",0,5,10,1,0},
    {"scanningMode",1,1,0,1,0}, {"exposurePriority",1,3,2,1,0},
    {"iris",1,9,7,2,0}, {"roll",1,15,13,2,1},
    {"privacy",1,17,18,1,0}, {"simpleFocus",1,18,19,1,0},
    {"hueAuto",0,16,11,1,0}, {"whiteBalanceComponentAuto",0,13,13,1,0},
    {"digitalMultiplier",0,14,14,2,0}, {"digitalMultiplierLimit",0,15,15,2,0},
    {"analogVideoStandard",0,17,16,1,0}, {"analogLockStatus",0,18,17,1,0},
    {"contrastAuto",0,19,18,1,0}
};

typedef struct {
    IOUSBDeviceInterface **device;
    uint8_t interface, terminal, processing;
    uint32_t terminal_bits, processing_bits;
    uint8_t extension_count;
    uint8_t extension_ids[16], extension_controls[16], extension_sizes[16];
    uint8_t extension_guids[16][16], extension_bits[16][32];
} Camera;

static uint32_t bits(const uint8_t *bytes, unsigned int length) {
    uint32_t value=0;
    for(unsigned int i=0;i<length && i<4;i++) value|=(uint32_t)bytes[i]<<(8*i);
    return value;
}

static IOReturn open_camera(uint32_t location, Camera *camera) {
    io_iterator_t iterator;
    IOReturn result=IOServiceGetMatchingServices(kIOMainPortDefault,IOServiceMatching(kIOUSBDeviceClassName),&iterator);
    if(result) return result;
    io_service_t service;
    result=kIOReturnNotFound;
    while((service=IOIteratorNext(iterator))) {
        IOCFPlugInInterface **plugin=NULL;
        SInt32 score;
        IOReturn created=IOCreatePlugInInterfaceForService(service,kIOUSBDeviceUserClientTypeID,kIOCFPlugInInterfaceID,&plugin,&score);
        IOObjectRelease(service);
        if(created || !plugin) continue;
        IOUSBDeviceInterface **device=NULL;
        (*plugin)->QueryInterface(plugin,CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID),(LPVOID *)&device);
        IODestroyPlugInInterface(plugin);
        if(!device) continue;
        UInt32 found=0;
        (*device)->GetLocationID(device,&found);
        if(found!=location) { (*device)->Release(device);continue; }
        result=(*device)->USBDeviceOpen(device);
        if(result) { (*device)->Release(device);break; }
        camera->device=device;
        IOUSBConfigurationDescriptorPtr descriptor=NULL;
        result=(*device)->GetConfigurationDescriptorPtr(device,0,&descriptor);
        if(result) break;
        const uint8_t *bytes=(const uint8_t *)descriptor;
        unsigned int total=OSSwapLittleToHostInt16(descriptor->wTotalLength);
        int video_control=0;
        for(unsigned int i=0;i+2<total && bytes[i]>=2 && i+bytes[i]<=total;i+=bytes[i]) {
            const uint8_t *d=bytes+i;
            if(d[1]==4 && d[0]>=9) {
                video_control=d[5]==14 && d[6]==1;
                if(video_control) camera->interface=d[2];
            }
            if(!video_control || d[1]!=0x24 || d[0]<4) continue;
            if(d[2]==2 && d[0]>=15 && d[4]==1 && d[5]==2 && d[0]>=15+d[14]) {
                camera->terminal=d[3];
                camera->terminal_bits=bits(d+15,d[14]);
            }
            if(d[2]==5 && d[0]>=8 && d[0]>=8+d[7]) {
                camera->processing=d[3];
                camera->processing_bits=bits(d+8,d[7]);
            }
            if(d[2]==6 && d[0]>=24 && camera->extension_count<16) {
                unsigned int pins=d[21],size_offset=22+pins;
                if(size_offset<d[0]) {
                    unsigned int control_size=d[size_offset];
                    if(control_size<=32 && size_offset+1+control_size<=d[0]) {
                        unsigned int index=camera->extension_count++;
                        camera->extension_ids[index]=d[3];
                        camera->extension_controls[index]=d[20];
                        camera->extension_sizes[index]=control_size;
                        memcpy(camera->extension_guids[index],d+4,16);
                        memcpy(camera->extension_bits[index],d+size_offset+1,control_size);
                    }
                }
            }
        }
        break;
    }
    IOObjectRelease(iterator);
    return result;
}

static void close_camera(Camera *camera) {
    if(camera->device) {
        (*camera->device)->USBDeviceClose(camera->device);
        (*camera->device)->Release(camera->device);
    }
}

static int supported(const Camera *camera,const Control *control) {
    uint32_t map=control->terminal?camera->terminal_bits:camera->processing_bits;
    return (map & (1u<<control->bit))!=0;
}

static IOReturn request(Camera *camera,const Control *control,uint8_t command,int64_t *value) {
    uint8_t bytes[4]={0};
    uint16_t length=command==0x86?1:control->size;
    if(command==1) for(unsigned int i=0;i<length;i++) bytes[i]=(uint8_t)((uint64_t)*value>>(8*i));
    IOUSBDevRequestTO req={0};
    req.bmRequestType=command==1?0x21:0xa1;
    req.bRequest=command;
    req.wValue=(uint16_t)control->selector<<8;
    req.wIndex=((uint16_t)(control->terminal?camera->terminal:camera->processing)<<8)|camera->interface;
    req.wLength=length;
    req.pData=bytes;
    req.noDataTimeout=1200;
    req.completionTimeout=1200;
    IOReturn result=(*camera->device)->DeviceRequestTO(camera->device,&req);
    if(result) return result;
    if(command!=1) {
        if(req.wLenDone!=length) return kIOReturnUnderrun;
        uint32_t raw=bits(bytes,length);
        if(command!=0x86 && control->signed_value) {
            *value=length==2?(int16_t)raw:(int32_t)raw;
        } else *value=raw;
    }
    return kIOReturnSuccess;
}

static int automatic(const Control *control) {
    return !strcmp(control->key,"focusAuto") || !strcmp(control->key,"whiteBalanceAuto");
}

static int bounds(Camera *camera,const Control *control,int64_t *minimum,int64_t *maximum,int64_t *step) {
    if(automatic(control) || !strcmp(control->key,"privacy") || !strcmp(control->key,"hueAuto") ||
       !strcmp(control->key,"whiteBalanceComponentAuto") || !strcmp(control->key,"contrastAuto") ||
       !strcmp(control->key,"exposurePriority") || !strcmp(control->key,"scanningMode")) {
        *minimum=0;*maximum=1;*step=1;return 1;
    }
    if(!strcmp(control->key,"exposureAuto")) { *minimum=1;*maximum=8;*step=1;return 1; }
    if(request(camera,control,0x82,minimum) || request(camera,control,0x83,maximum)) return 0;
    if(request(camera,control,0x84,step) || *step<=0) *step=1;
    return *minimum<=*maximum;
}

int main(int argc,char **argv) {
    if(argc!=3 && argc!=5) { fputs("usage: uvc-control LOCATION list | LOCATION set KEY VALUE\n",stderr);return 64; }
    char *end=NULL;
    errno=0;
    unsigned long location=strtoul(argv[1],&end,16);
    if(errno || *end || !location || location>UINT32_MAX) return 64;
    Camera camera={0};
    IOReturn result=open_camera((uint32_t)location,&camera);
    if(result) { fprintf(stderr,"USB control open failed: 0x%x\n",result);close_camera(&camera);return 1; }
    int exit_code=0;
    if(!strcmp(argv[2],"describe") && argc==3) {
        UInt16 vendor=0,product=0,release=0;
        UInt8 speed=0;
        (*camera.device)->GetDeviceVendor(camera.device,&vendor);
        (*camera.device)->GetDeviceProduct(camera.device,&product);
        (*camera.device)->GetDeviceReleaseNumber(camera.device,&release);
        (*camera.device)->GetDeviceSpeed(camera.device,&speed);
        printf("{\"locationID\":\"%lx\",\"vendorID\":%u,\"productID\":%u,\"firmwareBCD\":%u,"
               "\"usbSpeedCode\":%u,\"controlInterface\":%u,\"cameraTerminalID\":%u,"
               "\"processingUnitID\":%u,\"cameraTerminalBitmap\":%u,\"processingUnitBitmap\":%u,"
               "\"declaredControls\":[",location,vendor,product,release,speed,camera.interface,
               camera.terminal,camera.processing,camera.terminal_bits,camera.processing_bits);
        int count=0;
        for(unsigned int i=0;i<sizeof(controls)/sizeof(controls[0]);i++) {
            if(supported(&camera,&controls[i])) printf("%s\"%s\"",count++?",":"",controls[i].key);
        }
        printf("],\"extensionUnits\":[");
        for(unsigned int i=0;i<camera.extension_count;i++) {
            printf("%s{\"unitID\":%u,\"controlCount\":%u,\"guid\":\"",i?",":"",camera.extension_ids[i],camera.extension_controls[i]);
            for(unsigned int j=0;j<16;j++) printf("%02x",camera.extension_guids[i][j]);
            printf("\",\"controlBitmap\":\"");
            for(unsigned int j=0;j<camera.extension_sizes[i];j++) printf("%02x",camera.extension_bits[i][j]);
            printf("\"}");
        }
        puts("]}");
    } else if(!strcmp(argv[2],"list") && argc==3) {
        puts("[");
        int printed=0;
        for(unsigned int i=0;i<sizeof(controls)/sizeof(controls[0]);i++) {
            const Control *control=&controls[i];
            if(!supported(&camera,control)) continue;
            int64_t info=0,value=0,minimum=0,maximum=0,step=1,default_value=0;
            if(request(&camera,control,0x86,&info) || !(info&1) || request(&camera,control,0x81,&value) ||
               !bounds(&camera,control,&minimum,&maximum,&step)) continue;
            if(request(&camera,control,0x87,&default_value)) default_value=value;
            printf("%s{\"key\":\"%s\",\"value\":%lld,\"min\":%lld,\"max\":%lld,\"step\":%lld,\"defaultValue\":%lld,\"writable\":%s}",
                   printed++?",\n":"",control->key,value,minimum,maximum,step,default_value,(info&2)?"true":"false");
        }
        puts("\n]");
    } else if(!strcmp(argv[2],"set") && argc==5) {
        const Control *control=NULL;
        for(unsigned int i=0;i<sizeof(controls)/sizeof(controls[0]);i++) if(!strcmp(argv[3],controls[i].key)) control=&controls[i];
        errno=0;
        int64_t value=strtoll(argv[4],&end,10),minimum=0,maximum=0,step=1,info=0;
        if(!control || !supported(&camera,control) || errno || *end ||
           !bounds(&camera,control,&minimum,&maximum,&step) || value<minimum || value>maximum ||
           (value-minimum)%step || request(&camera,control,0x86,&info) || !(info&2) ||
           (!strcmp(control->key,"exposureAuto") && value!=1 && value!=2 && value!=4 && value!=8)) {
            fputs("Unsupported control or invalid value.\n",stderr);exit_code=64;
        } else {
            result=request(&camera,control,1,&value);
            if(result) { fprintf(stderr,"USB write failed: 0x%x\n",result);exit_code=1; }
            else {
                int64_t actual=0;
                int confirmed=0;
                for(int retry=0;retry<20;retry++) {
                    if(!request(&camera,control,0x81,&actual) &&
                       (actual==value || (!strcmp(control->key,"focus") && llabs(actual-value)<=4))) {
                        confirmed=1;break;
                    }
                    usleep(50000);
                }
                if(!confirmed) {
                    fprintf(stderr,"Camera did not confirm %s: requested %lld, read %lld.\n",control->key,value,actual);exit_code=1;
                } else printf("%lld\n",actual);
            }
        }
    } else exit_code=64;
    close_camera(&camera);
    return exit_code;
}
