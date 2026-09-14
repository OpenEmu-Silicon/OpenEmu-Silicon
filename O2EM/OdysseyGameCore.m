/*
 Copyright (c) 2014, OpenEmu Team


 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
     * Redistributions of source code must retain the above copyright
       notice, this list of conditions and the following disclaimer.
     * Redistributions in binary form must reproduce the above copyright
       notice, this list of conditions and the following disclaimer in the
       documentation and/or other materials provided with the distribution.
     * Neither the name of the OpenEmu Team nor the
       names of its contributors may be used to endorse or promote products
       derived from this software without specific prior written permission.

 THIS SOFTWARE IS PROVIDED BY OpenEmu Team ''AS IS'' AND ANY
 EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 DISCLAIMED. IN NO EVENT SHALL OpenEmu Team BE LIABLE FOR ANY
 DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
  LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "OdysseyGameCore.h"
#import "OEOdyssey2SystemResponderClient.h"

#import <OpenEmuBase/OERingBuffer.h>
#import <OpenEmuBase/OEMemoryRegionDescriptor.h>
#import <OpenGL/gl.h>
#include <IOKit/hid/IOHIDUsageTables.h>

#include "crc32.h"
#include "audio.h"
#include "vmachine.h"
#include "config.h"
#include "vdc.h"
#include "cpu.h"
#include "debug.h"
#include "keyboard.h"
#include "voice.h"
#include "vpp.h"

#include "wrapalleg.h"

#include "score.h"

#include "libretro.h"

@interface OdysseyGameCore () <OEOdyssey2SystemResponderClient>
{
    NSDictionary *virtualPhysicalKeyMap;
    NSMutableDictionary<NSString *, NSNumber *> *_cheatList;
}
@end

//uint16_t mbmp[EMUWIDTH * EMUHEIGHT];
//unsigned short int mbmp[TEX_WIDTH * TEX_HEIGHT];
uint16_t *mbmp;
//short signed int SNDBUF[1024*2];
uint8_t soundBuffer[1056];
int SND;
int RLOOP=0;
int joystick_data[2][5]={{0,0,0,0,0},{0,0,0,0,0}};

void update_joy(void){
}

int contax, o2flag, g74flag, c52flag, jopflag, helpflag;

unsigned long crcx = ~0;

static char bios[MAXC], scshot[MAXC], xrom[MAXC], romdir[MAXC], xbios[MAXC],
biosdir[MAXC], arkivo[MAXC][MAXC], biossux[MAXC], romssux[MAXC],
odyssey2[MAXC], g7400[MAXC], c52[MAXC], jopac[MAXC], file_l[MAXC], bios_l[MAXC],
file_v[MAXC],scorefile[MAXC], statefile[MAXC], path2[MAXC];

extern void retro_destroybmp(void);

static long filesize(FILE *stream){
    long curpos, length;
    curpos = ftell(stream);
    fseek(stream, 0L, SEEK_END);
    length = ftell(stream);
    fseek(stream, curpos, SEEK_SET);
    return length;
}

static void load_bios(const char *biosname){
	FILE *fn;
	static char s[MAXC+10];
	unsigned long crc;
	int i;
    
    if ((biosname[strlen(biosname)-1]=='/') ||
        (biosname[strlen(biosname)-1]=='\\') ||
        (biosname[strlen(biosname)-1]==':')) {
		strcpy(s,biosname);
		strcat(s,odyssey2);
		fn = fopen(s,"rb");
        
		if (!fn) {
			strcpy(s,biosname);
			strcat(s,odyssey2);
			fn = fopen(s,"rb");
        }
    } else {
        
    	strcpy(s,biosname);
		fn = fopen(biosname,"rb");
    }
	
    if (!fn) {
		fprintf(stderr,"Error loading bios ROM (%s)\n",s);
		exit(EXIT_FAILURE);
	}
 	if (fread(rom_table[0],1024,1,fn) != 1) {
 		fprintf(stderr,"Error loading bios ROM %s\n",odyssey2);
 		exit(EXIT_FAILURE);
 	}
    
    strcpy(s,biosname);
    fn = fopen(biosname,"rb");
    if (!fn) {
		fprintf(stderr,"Error loading bios ROM (%s)\n",s);
		exit(EXIT_FAILURE);
	}
 	if (fread(rom_table[0],1024,1,fn) != 1) {
 		fprintf(stderr,"Error loading bios ROM %s\n",odyssey2);
 		exit(EXIT_FAILURE);
 	}
    fclose(fn);
	for (i=1; i<8; i++) memcpy(rom_table[i],rom_table[0],1024);
	crc = crc32_buf(rom_table[0],1024);
	if (crc==0x8016A315) {
		printf("Odyssey2 bios ROM loaded\n");
		app_data.vpp = 0;
		app_data.bios = ROM_O2;
	} else if (crc==0xE20A9F41) {
		printf("Videopac+ G7400 bios ROM loaded\n");
		app_data.vpp = 1;
		app_data.bios = ROM_G7400;
	} else if (crc==0xA318E8D6) {
		if (!((!o2flag)&&(c52flag))) printf("C52 bios ROM loaded\n"); else printf("Ok\n");
		app_data.vpp = 0;
		app_data.bios = ROM_C52;
		
	} else if (crc==0x11647CA5) {
		if (g74flag) printf("Jopac bios ROM loaded\n"); else printf(" Ok\n");
		app_data.vpp = 1;
		app_data.bios = ROM_JOPAC;
	} else {
		printf("Bios ROM loaded (unknown version)\n");
		app_data.vpp = 0;
		app_data.bios = ROM_UNKNOWN;
	}
}

static void load_cart(const char *file){
	FILE *fn;
	long l;
	int i, nb;
    
	app_data.crc = crc32_file(file);
	if (app_data.crc == 0xAFB23F89) app_data.exrom = 1;  /* Musician */
	if (app_data.crc == 0x3BFEF56B) app_data.exrom = 1;  /* Four in 1 Row! */
	if (app_data.crc == 0x9B5E9356) app_data.exrom = 1;  /* Four in 1 Row! (french) */
    
	if (((app_data.crc == 0x975AB8DA) || (app_data.crc == 0xE246A812)) && (!app_data.debug)) {
		fprintf(stderr,"Error: file %s is an incomplete ROM dump\n",file_v);
		exit(EXIT_FAILURE);
	}
	
    fn=fopen(file,"rb");
	if (!fn) {
		fprintf(stderr,"Error loading %s\n",file_v);
		exit(EXIT_FAILURE);
	}
	printf("Loading: \"%s\"  Size: ",file_v);
	l = filesize(fn);
	
    if ((l % 1024) != 0) {
		fprintf(stderr,"Error: file %s is an invalid ROM dump\n",file_v);
		exit(EXIT_FAILURE);
	}
    
    /* special MegaCART design by Soeren Gust */
	if ((l == 32768) || (l == 65536) || (l == 131072) || (l == 262144) || (l == 524288) || (l == 1048576)) {
		app_data.megaxrom = 1;
		app_data.bank = 1;
		megarom = malloc(1048576);
		if (megarom == NULL) {
			fprintf(stderr, "Out of memory loading %s\n", file);
			exit(EXIT_FAILURE);
        }
		if (fread(megarom, l, 1, fn) != 1) {
			fprintf(stderr,"Error loading %s\n",file);
			exit(EXIT_FAILURE);
		}
		
        /* mirror shorter files into full megabyte */
		if (l < 65536) memcpy(megarom+32768,megarom,32768);
		if (l < 131072) memcpy(megarom+65536,megarom,65536);
		if (l < 262144) memcpy(megarom+131072,megarom,131072);
		if (l < 524288) memcpy(megarom+262144,megarom,262144);
		if (l < 1048576) memcpy(megarom+524288,megarom,524288);
		/* start in bank 0xff */
		memcpy(&rom_table[0][1024], megarom + 4096*255 + 1024, 3072);
		printf("MegaCart %ldK", l / 1024);
		nb = 1;
	} else if (((l % 3072) == 0))
    {
		app_data.three_k = 1;
		nb = l/3072;
        
		for (i=nb-1; i>=0; i--) {
			if (fread(&rom_table[i][1024],3072,1,fn) != 1) {
				fprintf(stderr,"Error loading %s\n",file);
				exit(EXIT_FAILURE);
			}
		}
		printf("%dK",nb*3);
        
	} else {
        
		nb = l/2048;
        
		if ((nb == 2) && (app_data.exrom)) {
            
			if (fread(&extROM[0], 1024,1,fn) != 1) {
				fprintf(stderr,"Error loading %s\n",file);
				exit(EXIT_FAILURE);
			}
			if (fread(&rom_table[0][1024],3072,1,fn) != 1) {
				fprintf(stderr,"Error loading %s\n",file);
				exit(EXIT_FAILURE);
			}
			printf("3K EXROM");
            
		} else {
            
			for (i=nb-1; i>=0; i--) {
				if (fread(&rom_table[i][1024],2048,1,fn) != 1) {
					fprintf(stderr,"Error loading %s\n",file);
					exit(EXIT_FAILURE);
				}
				memcpy(&rom_table[i][3072],&rom_table[i][2048],1024); /* simulate missing A10 */
			}
			printf("%dK",nb*2);
            
		}
	}
	fclose(fn);
	rom = rom_table[0];
	if (nb==1)
        app_data.bank = 1;
	else if (nb==2)
		app_data.bank = app_data.exrom ? 1 : 2;
	else if (nb==4)
		app_data.bank = 3;
	else
		app_data.bank = 4;
	
    if ((rom_table[nb-1][1024+12]=='O') && (rom_table[nb-1][1024+13]=='P') && (rom_table[nb-1][1024+14]=='N') && (rom_table[nb-1][1024+15]=='B')) app_data.openb=1;
	
    printf("  CRC: %08lX\n",app_data.crc);
}

//int suck_bios()
//{
//    int i;
//    for (i=0; i<contax; ++i)
//    {
//        strcpy(biossux,biosdir);
//        strcat(biossux,arkivo[i]);
//        identify_bios(biossux);
//    }
//    return(0);
//}
/********************* Search ROM */
//int suck_roms()
//{
//    int i;
//    rom_f = 1;
//    for (i=0; i<contax; ++i)
//    {
//        strcpy(romssux,romdir);
//        strcat(romssux,arkivo[i]);
//        app_data.crc = crc32_file(romssux);
//        if (app_data.crc == crcx)
//        {
//            if ((app_data.crc == 0xD7089068)||(app_data.crc == 0xB0A7D723)||
//                (app_data.crc == 0x0CA26992)||(app_data.crc == 0x0B6EB25B)||
//                (app_data.crc == 0x06861A9C)||(app_data.crc == 0xB2F0F0B4)||
//                (app_data.crc == 0x68560DC7)||(app_data.crc == 0x0D2D721D)||
//                (app_data.crc == 0xC4134DF8)||(app_data.crc == 0xA75C42F8))
//                rom_f = 0;
//        }
//    }
//    return(0);
//}
/********************* Ready BIOS */
//int identify_bios(char *biossux)
//{
//    app_data.crc = crc32_file(biossux);
//    if (app_data.crc == 0x8016A315){
//        strcpy(odyssey2, biossux);
//        o2flag = 1;
//    }
//    if (app_data.crc == 0xE20A9F41){
//        strcpy(g7400, biossux);
//        g74flag = 1;
//    }
//    if (app_data.crc == 0xA318E8D6){
//        strcpy(c52, biossux);
//        c52flag = 1;
//    }
//    if (app_data.crc == 0x11647CA5){
//        strcpy(jopac, biossux);
//        jopflag = 1;
//    }
//    return(0);
//}

OdysseyGameCore *current;
@implementation OdysseyGameCore

- (id)init
{
    if((self = [super init]))
    {
        current = self;
        
        virtualPhysicalKeyMap = @{ @(kHIDUsage_Keyboard0) : @(RETROK_0),
                                   @(kHIDUsage_Keyboard1) : @(RETROK_1),
                                   @(kHIDUsage_Keyboard2) : @(RETROK_2),
                                   @(kHIDUsage_Keyboard3) : @(RETROK_3),
                                   @(kHIDUsage_Keyboard4) : @(RETROK_4),
                                   @(kHIDUsage_Keyboard5) : @(RETROK_5),
                                   @(kHIDUsage_Keyboard6) : @(RETROK_6),
                                   @(kHIDUsage_Keyboard7) : @(RETROK_7),
                                   @(kHIDUsage_Keyboard8) : @(RETROK_8),
                                   @(kHIDUsage_Keyboard9) : @(RETROK_9),
                                   @(kHIDUsage_KeyboardA) : @(RETROK_a),
                                   @(kHIDUsage_KeyboardB) : @(RETROK_b),
                                   @(kHIDUsage_KeyboardC) : @(RETROK_c),
                                   @(kHIDUsage_KeyboardD) : @(RETROK_d),
                                   @(kHIDUsage_KeyboardE) : @(RETROK_e),
                                   @(kHIDUsage_KeyboardF) : @(RETROK_f),
                                   @(kHIDUsage_KeyboardG) : @(RETROK_g),
                                   @(kHIDUsage_KeyboardH) : @(RETROK_h),
                                   @(kHIDUsage_KeyboardI) : @(RETROK_i),
                                   @(kHIDUsage_KeyboardJ) : @(RETROK_j),
                                   @(kHIDUsage_KeyboardK) : @(RETROK_k),
                                   @(kHIDUsage_KeyboardL) : @(RETROK_l),
                                   @(kHIDUsage_KeyboardM) : @(RETROK_m),
                                   @(kHIDUsage_KeyboardN) : @(RETROK_n),
                                   @(kHIDUsage_KeyboardO) : @(RETROK_o),
                                   @(kHIDUsage_KeyboardP) : @(RETROK_p),
                                   @(kHIDUsage_KeyboardQ) : @(RETROK_q),
                                   @(kHIDUsage_KeyboardR) : @(RETROK_r),
                                   @(kHIDUsage_KeyboardS) : @(RETROK_s),
                                   @(kHIDUsage_KeyboardT) : @(RETROK_t),
                                   @(kHIDUsage_KeyboardU) : @(RETROK_u),
                                   @(kHIDUsage_KeyboardV) : @(RETROK_v),
                                   @(kHIDUsage_KeyboardW) : @(RETROK_w),
                                   @(kHIDUsage_KeyboardX) : @(RETROK_x),
                                   @(kHIDUsage_KeyboardY) : @(RETROK_y),
                                   @(kHIDUsage_KeyboardZ) : @(RETROK_z),
                                   @(kHIDUsage_KeyboardSpacebar) : @(RETROK_SPACE),
                                   @(kHIDUsage_KeyboardSlash) : @(RETROK_QUESTION),
                                   @(kHIDUsage_KeyboardPeriod) : @(RETROK_PERIOD),
                                   @(kHIDUsage_KeyboardDeleteOrBackspace) : @(RETROK_END),
                                   @(kHIDUsage_KeyboardReturnOrEnter) : @(RETROK_RETURN),
                                   @(kHIDUsage_KeyboardHyphen) : @(RETROK_MINUS),
                                   //@(kHIDUsage_KeyboardSpacebar) : @(RETROK_ASTERISK),
                                   //@(kHIDUsage_KeyboardSpacebar) : @(RETROK_SLASH),
                                   //@(kHIDUsage_KeyboardSpacebar) : @(RETROK_EQUALS),
                                   //@(kHIDUsage_KeyboardSpacebar) : @(RETROK_PLUS),
                                };
    }
    
    return self;
}

- (void)dealloc
{
    close_audio();
	close_voice();
	close_display();
	retro_destroybmp();
    if(mbmp)
    {
        free(mbmp);
    }
}

#pragma mark Execution

- (BOOL)loadFileAtPath:(NSString *)path
{
    RLOOP=1;
    
	static char file[MAXC], attr[MAXC], val[MAXC], *p, *binver;
    
    app_data.debug = 0;
	app_data.stick[0] = app_data.stick[1] = 1;
	app_data.sticknumber[0] = app_data.sticknumber[1] = 0;
	set_defjoykeys(0,0);
	set_defjoykeys(1,1);
	set_defsystemkeys();
	app_data.bank = 0;
	app_data.limit = 1;
	app_data.sound_en = 1;
	app_data.speed = 100;
	app_data.wsize = 2;
	app_data.fullscreen = 0;
	app_data.scanlines = 0;
	app_data.voice = 1;
	app_data.window_title = "O2EM v" O2EM_VERSION;
	app_data.svolume = 100;
	app_data.vvolume = 100;
	app_data.filter = 0;
	app_data.exrom = 0;
	app_data.three_k = 0;
	app_data.crc = 0;
	app_data.scshot = scshot;
	app_data.statefile = statefile;
	app_data.euro = 0;
	app_data.openb = 0;
	app_data.vpp = 0;
	app_data.bios = 0;
	app_data.scoretype = 0;
	app_data.scoreaddress = 0;
	app_data.default_highscore = 0;
	app_data.breakpoint = 65535;
	app_data.megaxrom = 0;
	strcpy(file,"");
	strcpy(file_l,"");
	strcpy(bios_l,"");
    strcpy(bios,"");
	strcpy(scshot,"");
	strcpy(statefile,"");
    strcpy(xrom,"");
	strcpy(scorefile,"highscore.txt");
	//read_default_config();
    
    init_audio();
    
    app_data.crc = crc32_file([path fileSystemRepresentation]);
    
    //suck_bios();
    o2flag = 1;
    
    crcx = app_data.crc;
    //suck_roms();
    
    NSString *biosROM = [[self biosDirectoryPath] stringByAppendingPathComponent:@"o2rom.bin"];
    load_bios([biosROM fileSystemRepresentation]);
    
	load_cart([path fileSystemRepresentation]);
	//if (app_data.voice) load_voice_samples(path2);
    
	init_display();
    
	init_cpu();
    
	init_system();
    
    set_score(app_data.scoretype, app_data.scoreaddress, app_data.default_highscore);
    
    return YES;
}

- (void)executeFrame
{
    //run();
    cpu_exec();

    for (NSString *key in _cheatList) {
        if (![_cheatList[key] boolValue]) continue;
        NSArray<NSString *> *codes = [key componentsSeparatedByString:@"+"];
        for (NSString *singleCode in codes) {
            NSRange colonRange = [singleCode rangeOfString:@":"];
            if (colonRange.location == NSNotFound) continue;
            unsigned int addr = 0, val = 0;
            if (![[NSScanner scannerWithString:[singleCode substringToIndex:colonRange.location]] scanHexInt:&addr]) continue;
            if (![[NSScanner scannerWithString:[singleCode substringFromIndex:colonRange.location + 1]] scanHexInt:&val]) continue;
            // 0x000-0x03F: internal RAM (64 bytes, universal); 0x100-0x1FF: external RAM (256 bytes, cart-dependent)
            if (addr < 0x40)
                intRAM[addr] = (Byte)val;
            else if (addr >= 0x100 && addr < 0x200)
                extRAM[addr - 0x100] = (Byte)val;
        }
    }

    int len = evblclk == EVBLCLK_NTSC ? 44100/60 : 44100/50;

    // Convert 8u to 16s
    for(int i = 0; i < len; i++)
    {
        int16_t sample16 = (soundBuffer[i] - 128 ) << 8;

        [[current audioBufferAtIndex:0] write:&sample16 maxLength:2];
    }

    RLOOP=1;
}

- (void)resetEmulation
{
    init_cpu();
    init_roms();
    init_vpp();
    clearscr();
}

#pragma mark Video

- (OEIntSize)aspectSize
{
    return OEIntSizeMake(EMUWIDTH, EMUHEIGHT);
}

- (OEIntRect)screenRect
{
    return OEIntRectMake(0, 0, EMUWIDTH, EMUHEIGHT);
}

- (OEIntSize)bufferSize
{
    return OEIntSizeMake(TEX_WIDTH, TEX_HEIGHT);
}

- (const void *)getVideoBufferWithHint:(void *)hint
{
    if(!hint)
    {
        if(!mbmp)
        {
            hint = mbmp = (uint16_t*)malloc(TEX_WIDTH * TEX_HEIGHT * sizeof(uint16_t));
        }
    }
    else
    {
        mbmp = hint;
    }

    return mbmp;
}

- (GLenum)pixelFormat
{
    return GL_RGB;
}

- (GLenum)pixelType
{
    return GL_UNSIGNED_SHORT_5_6_5;
}

- (NSTimeInterval)frameInterval
{
    return 60;
}

#pragma mark Audio

- (NSUInteger)channelCount
{
    return 1;
}

- (double)audioSampleRate
{
    return 44100;
}

- (NSUInteger)audioBitDepth
{
    return 16;
}

#pragma mark Input

- (void)keyDown:(unsigned short)keyCode
{
    NSNumber *virtualCode = [virtualPhysicalKeyMap objectForKey:@(keyCode)];

    if(virtualCode)
        key[[virtualCode intValue]] = 1;
}

- (void)keyUp:(unsigned short)keyCode
{
    NSNumber *virtualCode = [virtualPhysicalKeyMap objectForKey:@(keyCode)];

    if(virtualCode)
        key[[virtualCode intValue]] = 0;
}

- (oneway void)didPushOdyssey2Button:(OEOdyssey2Button)button forPlayer:(NSUInteger)player;
{
    player--;
    if (button == OEOdyssey2ButtonUp)
        joystick_data[player][0] = 1;
    else if (button == OEOdyssey2ButtonDown)
        joystick_data[player][1] = 1;
    else if (button == OEOdyssey2ButtonLeft)
        joystick_data[player][2] = 1;
    else if (button == OEOdyssey2ButtonRight)
        joystick_data[player][3] = 1;
    else if (button == OEOdyssey2ButtonAction)
        joystick_data[player][4] = 1;
}

- (oneway void)didReleaseOdyssey2Button:(OEOdyssey2Button)button forPlayer:(NSUInteger)player;
{
    player--;
    if (button == OEOdyssey2ButtonUp)
        joystick_data[player][0] = 0;
    else if (button == OEOdyssey2ButtonDown)
        joystick_data[player][1] = 0;
    else if (button == OEOdyssey2ButtonLeft)
        joystick_data[player][2] = 0;
    else if (button == OEOdyssey2ButtonRight)
        joystick_data[player][3] = 0;
    else if (button == OEOdyssey2ButtonAction)
        joystick_data[player][4] = 0;
}

- (void)saveStateToFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
    block(savestate(fileName.fileSystemRepresentation) ? YES : NO, nil);
}

- (void)loadStateFromFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
    block(loadstate(fileName.fileSystemRepresentation) ? YES : NO, nil);
}

#pragma mark Cheats

- (void)setCheat:(NSString *)code setType:(NSString *)type setEnabled:(BOOL)enabled
{
    if (!_cheatList)
        _cheatList = [NSMutableDictionary dictionary];

    code = [code stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    code = [code stringByReplacingOccurrencesOfString:@" " withString:@""];

    if (enabled)
        _cheatList[code] = @YES;
    else
        [_cheatList removeObjectForKey:code];
}

- (NSArray<OEMemoryRegionDescriptor *> *)readableMemoryRegions
{
    NSData *intData = [NSData dataWithBytes:intRAM length:64];
    NSData *extData = [NSData dataWithBytes:extRAM length:256];

    OEMemoryRegionDescriptor *intDescriptor = [OEMemoryRegionDescriptor descriptorWithName:@"Internal RAM"
                                                                                    address:0x0000
                                                                               addressBytes:2
                                                                                       data:intData];
    OEMemoryRegionDescriptor *extDescriptor = [OEMemoryRegionDescriptor descriptorWithName:@"External RAM"
                                                                                    address:0x0100
                                                                               addressBytes:2
                                                                                       data:extData];
    return @[intDescriptor, extDescriptor];
}

@end
