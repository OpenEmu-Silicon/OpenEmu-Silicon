/*
 Copyright (c) 2016, OpenEmu Team
 
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

#include "DolHost.h"
#include "OpenEmuInput.h"
#include "OpenEmuController.h"

#import  <Cocoa/Cocoa.h>

#include "AudioCommon/AudioCommon.h"

#include "Common/CPUDetect.h"
#include "Common/CommonPaths.h"
#include "Common/CommonTypes.h"
#include "Common/FileUtil.h"
#include "Common/IniFile.h"
#include "Common/Logging/LogManager.h"
#include "Common/MsgHandler.h"
#include "Common/Thread.h"
#include "Common/Version.h"

#include "Core/DolphinAnalytics.h"
#include "Core/Boot/Boot.h"
#include "Core/BootManager.h"
#include "Core/Config/MainSettings.h"
#include "Core/Config/WiimoteSettings.h"
#include "Core/ConfigManager.h"
#include "Core/Core.h"
#include "Core/Host.h"
#include "Core/HW/CPU.h"
#include "Core/HW/Wiimote.h"
#include "Core/HW/WiimoteCommon/WiimoteHid.h"
#include "Core/HW/WiimoteReal/WiimoteReal.h"
#include "Core/HW/WiimoteEmu/WiimoteEmu.h"
#include "Core/HW/ProcessorInterface.h"
#include "Core/IOS/IOS.h"
#include "Core/IOS/STM/STM.h"
#include "Core/PowerPC/PowerPC.h"
#include "Core/State.h"
#include "Core/WiiUtils.h"

#include "UICommon/CommandLineParse.h"
#include "UICommon/UICommon.h"

#include "InputCommon/InputConfig.h"
#include "InputCommon/ControllerEmu/ControlGroup/Attachments.h"
#include "InputCommon/ControllerEmu/ControlGroup/Cursor.h"
#include "InputCommon/ControllerEmu/Control/Control.h"
#include "InputCommon/ControlReference/ControlReference.h"

//#include "VideoCommon/RenderBase.h"
#include "VideoCommon/VideoBackendBase.h"
#include "VideoCommon/VideoConfig.h"
#include "VideoCommon/OnScreenDisplay.h"

#include "Core/Config/MainSettings.h"
#include "Core/ConfigManager.h"

DolHost* DolHost::m_instance = nullptr;
static Common::Event updateMainFrameEvent;
static Common::Flag s_running{true};

static Common::Flag s_shutdown_requested{false};
static Common::Flag s_tried_graceful_shutdown{false};

WindowSystemInfo wsi(WindowSystemType::Headless, nullptr, nullptr, nullptr);
 
DolHost* DolHost::GetInstance()
{
    if (DolHost::m_instance == nullptr)
        DolHost::m_instance = new DolHost();
    return DolHost::m_instance;
}

DolHost::DolHost()
{
}

void DolHost::Init(std::string supportDirectoryPath, std::string cpath)
{
    // Set the game file for the DolHost
    _gamePath = cpath;
    
    //Configure UI for OpenEmu directory structure
    UICommon::SetUserDirectory(supportDirectoryPath);
    UICommon::CreateDirectories();
    
    // Init the UI
    UICommon::Init();
    
    // Database Settings
    Config::SetBase(Config::MAIN_USE_BUILT_IN_TITLE_DATABASE, true);
    
    //Setup the CPU Settings
    Config::SetBase(Config::MAIN_ENABLE_CHEATS, true);
    SConfig::GetInstance().bBootToPause = false;
    
    //Debug Settings
    Config::SetBase(Config::MAIN_ENABLE_DEBUGGING, false);
#ifdef DEBUG
    Config::SetBase(Config::MAIN_OSD_MESSAGES, true);
#else
    Config::SetBase(Config::MAIN_OSD_MESSAGES, false);
#endif
    Config::SetBase(Config::MAIN_SHOW_FRAME_COUNT, false);
    
    //Video
    Config::SetBase(Config::MAIN_GFX_BACKEND, "Metal");
    VideoBackendBase::ActivateBackend(Config::Get(Config::MAIN_GFX_BACKEND));
    
    //Set the Sound
    Config::SetBase(Config::MAIN_DSP_HLE, true);
    Config::SetBase(Config::MAIN_DSP_THREAD, true);
    Config::SetBase(Config::MAIN_AUDIO_VOLUME, 100);
    
    // Dual-core mode: CPU and GPU on separate threads for better performance.
    // HostDispatchJobs is called from OE's UpdateFrame() loop and is thread-safe in both modes.
    Config::SetBase(Config::MAIN_CPU_THREAD, true);
    
    //Analitics
    Config::SetBase(Config::MAIN_ANALYTICS_PERMISSION_ASKED, true);
    Config::SetBase(Config::MAIN_ANALYTICS_ENABLED, false);
    DolphinAnalytics::Instance().ReloadConfig();
    
    //Save them now
    SConfig::GetInstance().SaveSettings();
    
    //Choose Wiimote Type
    Config::SetCurrent(Config::GetInfoForWiimoteSource(0), WiimoteSource::Emulated);
    Config::SetCurrent(Config::GetInfoForWiimoteSource(1), WiimoteSource::Emulated);
    Config::SetCurrent(Config::GetInfoForWiimoteSource(2), WiimoteSource::Emulated);
    Config::SetCurrent(Config::GetInfoForWiimoteSource(3), WiimoteSource::Emulated);
    
    //Get game info from file path
    GetGameInfo();
    
    if (!DiscIO::IsWii(_gameType))
    {
		Core::System::GetInstance().SetIsWii(false);
        
        //Set the wii format to false
        _wiiWAD = false;
        
        //Create Memorycards by GameID
        std::string _memCardPath = File::GetUserPath(D_GCUSER_IDX) + DIR_SEP + _gameCountryDir + DIR_SEP + _gameID;
        std::string _memCardA = _memCardPath + "_A." + _gameCountryDir + ".raw";
        std::string _memCardB = _memCardPath +  "_B." + _gameCountryDir + ".raw";
        
        //SConfig::GetInstance().m_strMemoryCardA = _memCardA;
        //SConfig::GetInstance().m_strMemoryCardB = _memCardB;
    }
    else
    {
		Core::System::GetInstance().SetIsWii(true);
        
        //Set the wii type
        if (_gameType ==  DiscIO::Platform::WiiWAD)
            _wiiWAD = true;
        else
            _wiiWAD = false;
        
        //clear the GC mem card paths
        //SConfig::GetInstance().m_strMemoryCardA = "";
        //SConfig::GetInstance().m_strMemoryCardB = "";
        
        //Disable WiiNAD checks
       // SConfig::GetInstance().m_enable_signature_checks = false;
        
        // Disable wiimote continuous scanning
        Config::SetBase(Config::MAIN_WIIMOTE_CONTINUOUS_SCANNING, false);
        
        //Set the Wiimote type
//        WiimoteReal::ChangeWiimoteSource(0, _wiiMoteType);
//        WiimoteReal::ChangeWiimoteSource(1, _wiiMoteType);
//        WiimoteReal::ChangeWiimoteSource(2, _wiiMoteType);
//        WiimoteReal::ChangeWiimoteSource(3, _wiiMoteType);
    }
}

# pragma mark - Execution
bool DolHost::LoadFileAtPath()
{
    Core::AddOnStateChangedCallback([](Core::State state) {
        if (state == Core::State::Uninitialized)
            s_running.Clear();
    });
	auto &system = Core::System::GetInstance();

    //    DolphinAnalytics::Instance()->ReportDolphinStart("openEmu");
    //
    //    if (_wiiWAD)
    //        WiiUtils::InstallWAD(_gamePath);
    //    //    else
    //    //        WiiUtils::DoDiscUpdate(nil, _gameRegionName);

    // Provide the sizing layer so Dolphin's Metal backend reads the correct surface dimensions.
    if (m_metalLayer) {
        wsi.type = WindowSystemType::MacOS;
        wsi.render_surface = (__bridge void*)m_metalLayer;
    }

    // Initialize input BEFORE booting. EmuThread (spawned by BootCore) asserts
    // g_controller_interface.IsInit() during its early init, so the controller
    // interface must already be initialized when BootCore starts the emu thread.
    // Doing this after BootCore races the emu thread and hard-traps on first boot
    // (issue #615); on a retry the global was already initialized by the first
    // attempt, which is why the second launch "worked". This matches upstream
    // Dolphin's frontend ordering (host initializes input, then boots).
    Input::Openemu_Input_Init();

    //Add 4 Joypads
    for (int i = 0; i < 4; i++)
        Input::openemu_set_controller_port_device(i, OEDolDevJoy);

    if (!BootManager::BootCore(system, BootParameters::GenerateFromFile(_gamePath), wsi))
        return false;

    init_Callback();
    
    while (!Core::IsRunningOrStarting(system) && s_running.IsSet())
    {
        Core::HostDispatchJobs(system);
    }
    
    Core::SetState(system, Core::State::Running);
    
    return true;
}

void DolHost::Pause(bool flag)
{
    Core::State state = flag ? Core::State::Paused : Core::State::Running;
    Core::SetState(Core::System::GetInstance(), state);
}

void DolHost::RequestStop()
{
	auto &system = Core::System::GetInstance();
    Core::SetState(system, Core::State::Running);
	system.GetProcessorInterface().PowerButton_Tap();
    
    Core::Stop(system);
    while (system.GetCPU().GetState() != CPU::State::PowerDown)
        usleep(1000);
    
    Core::Shutdown(system);
    UICommon::Shutdown();
}

void DolHost::Reset()
{
	Core::System::GetInstance().GetProcessorInterface().PowerButton_Tap();
}

void DolHost::UpdateFrame()
{
    // Dispatch any pending host jobs (state changes, UI callbacks) each frame
    Core::HostDispatchJobs(Core::System::GetInstance());

    //Input::OpenEmu_Input_Update();

    if(_onBoot) _onBoot = false;
}

bool DolHost::CoreRunning()
{
    if (Core::GetState(Core::System::GetInstance()) == Core::State::Running)
        return true;
    
    return false;
}

# pragma mark - Metal render target

// Forward declaration — avoids including MTLGfx.h (which pulls in MRCHelpers.h, no-ARC only).
namespace Metal { void GfxSetOETexture(id<MTLTexture> texture); }

void DolHost::SetMetalLayer(CAMetalLayer* layer)
{
    m_metalLayer = layer;
}

void DolHost::SetMetalTexture(id<MTLTexture> texture)
{
    Metal::GfxSetOETexture(texture);
}


# pragma mark - Audio 
void DolHost::SetVolume(float value)
{
    Config::SetBaseOrCurrent(Config::MAIN_AUDIO_VOLUME, value * 100);
    AudioCommon::UpdateSoundStream(Core::System::GetInstance());
}

# pragma mark - Save states
bool DolHost::setAutoloadFile(std::string saveStateFile)
{
    DolHost::LoadState(saveStateFile);
    return true;
}

bool DolHost::SaveState(std::string saveStateFile)
{
    State::SaveAs(Core::System::GetInstance(), saveStateFile);
    return true;
}

bool DolHost::LoadState(std::string saveStateFile)
{
    auto &system = Core::System::GetInstance();

    // State::LoadAs applies the save via Core::RunOnCPUThread, which only hands DoState to the CPU
    // thread once the core is fully Running (s_state == Running). OpenEmu can auto-load while the
    // boot is still in the Starting phase — _isInitialized is set as soon as LoadFileAtPath returns,
    // before the CPU thread is operational — in which case RunOnCPUThread runs DoState inline on
    // this thread and trips DVDThread::WaitUntilIdle's IsCPUThread() assertion. Wait (capped) for
    // the CPU thread to come up, and skip the load rather than crash if it never does.
    for (int i = 0; i < 3000 && !Core::IsRunning(system); ++i)
        usleep(1000);

    if (!Core::IsRunning(system))
        return false;

    State::LoadAs(system, saveStateFile);
    
    if (DiscIO::IsWii(_gameType))
    {
        // We have to set the wiimote type, cause the gamesave may
        //    have used a different type
//        WiimoteReal::ChangeWiimoteSource(0 , _wiiMoteType);
//        WiimoteReal::ChangeWiimoteSource(1 , _wiiMoteType);
//        WiimoteReal::ChangeWiimoteSource(2 , _wiiMoteType);
//        WiimoteReal::ChangeWiimoteSource(3 , _wiiMoteType);
//        
//        if( _wiiMoteType != WIIMOTE_SRC_EMU)
//            WiimoteReal::Refresh();
    }
    return true;
}

# pragma mark - Cheats
void DolHost::SetCheat(std::string code, std::string type, bool enabled)
{
    gcode.codes.clear();
    gcode.enabled = enabled;
    arcode.ops.clear();
    arcode.enabled = enabled;
    
    Gecko::GeckoCode::Code gcodecode;
    uint32_t cmd_addr, cmd_value;
    
    std::vector<std::string> arcode_encrypted_lines;
    
    //Get the code sent and sanitize it.
    NSString* nscode = [NSString stringWithUTF8String:code.c_str()];
    
    //Remove whitespace
    nscode = [nscode stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    
    // Remove any spaces and dashes
    nscode = [nscode stringByReplacingOccurrencesOfString:@" " withString:@""];
    nscode = [nscode stringByReplacingOccurrencesOfString:@"-" withString:@""];
    
    //Check if it is a valid Gecko or ActionReplay code
    NSString *singleCode;
    NSArray *multipleCodes = [nscode componentsSeparatedByString:@"+"];
    
    for (singleCode in multipleCodes)
    {
        if ([singleCode length] == 16) // Gecko code
        {
            NSString *address = [singleCode substringWithRange:NSMakeRange(0, 8)];
            NSString *value = [singleCode substringWithRange:NSMakeRange(8, 8)];
            
            bool success_addr = TryParse(std::string("0x") + [address UTF8String], &cmd_addr);
            bool success_val = TryParse(std::string("0x") + [value UTF8String], &cmd_value);
            
            if (!success_addr || !success_val)
                return;
            
            gcodecode.address = cmd_addr;
            gcodecode.data = cmd_value;
            gcode.codes.push_back(gcodecode);
        }
        else if ([singleCode length] == 13) // Encrypted AR code
        {
            // Add the code to list encrypted lines
            arcode_encrypted_lines.emplace_back([singleCode UTF8String]);
        }
        else
        {
            // Not a good code
            return;
        }
    }
    
    if (arcode_encrypted_lines.size())
    {
        DecryptARCode(arcode_encrypted_lines,  &arcode.ops);
    }
    
    bool exists = false;
    
    //Check to make sure the Gecko codes are not already in the list
    //  cycle through the codes in our Gecko vector
    for (Gecko::GeckoCode& gcompare : gcodes)
    {
        //If the code being modified is the same size as one in the vector, check each value
        if (gcompare.codes.size() == gcode.codes.size())
        {
            for(int i = 0; i < gcode.codes.size() ;i++)
            {
                if (gcompare.codes[i].address == gcode.codes[i].address && gcompare.codes[i].data == gcode.codes[i].data)
                {
                    exists = true;
                }
                else
                {
                    exists = false;
                    // If it's not the same, no need to look through all the codes
                    break;
                }
            }
        }
        if(exists)
        {
            gcompare.enabled = enabled;
            // If it exists, enable it, and we don't need to look at the rest of the codes
            break;
        }
    }
    
    if(!exists)
        gcodes.push_back(gcode);
    
    Gecko::SetActiveCodes(gcodes, _gameID, 0);
    
    
    //Check to make sure the ARcode is not already in the list
    //  cycle through the codes in our AR vector
    for (ActionReplay::ARCode& acompare : arcodes)
    {
        if (acompare.ops.size() == arcode.ops.size())
        {
            for(int i = 0; i < arcode.ops.size() ;i++)
            {
                if (acompare.ops[i].cmd_addr == arcode.ops[i].cmd_addr && acompare.ops[i].value == arcode.ops[i].value)
                {
                    exists = true;
                }
                else
                {
                    exists = false;
                    // If it's not the same, no need to look through all the codes
                    break;
                }
            }
        }
        if(exists)
        {
            acompare.enabled = enabled;
            // If it exists, enable it, and we don't need to look at the rest of the codes
            break;
        }
    }
    
    if(!exists)
        arcodes.push_back(arcode);
    
    {
        Core::CPUThreadGuard cpu_guard(Core::System::GetInstance());
        ActionReplay::RunAllActive(cpu_guard);
    }
}

# pragma mark - Controls
void DolHost::DisplayMessage(std::string message)
{
}

void DolHost::setButtonState(int button, int state, int player)
{
    player -= 1;
    if (_gameType == DiscIO::Platform::GameCubeDisc) {
        setGameCubeButton(player, button, state);
    } else {
        setWiiButton(player, button, state);
    }
}

void DolHost::SetAxis(int button, float value, int player)
{
    player -= 1;
    if (_gameType == DiscIO::Platform::GameCubeDisc) {
        setGameCubeAxis(player, button, value);
        if (button == OEGCButtonR || button == OEGCButtonL) {
            int digVal = 0;
            if (value == 1) digVal = 1;
            setGameCubeButton(player, button + 5, digVal);
        }
    } else {
        setWiiAxis(player, button, value);
    }
}

void DolHost::processSpecialKeys (int button , int player)
{
    player -= 1;
    button += 1;
    
    if (button == OEWiimoteSideways) {
        _wmSideways[player] = !_wmSideways[player];
        setWiimoteSideways(player);
    } else if (button == OEWiimoteUpright) {
        _wmUpright[player] = !_wmUpright[player];
       setWiimoteUpright(player);
    }
}
void DolHost::setWiimoteSideways (int player)
{
    static_cast<ControllerEmu::NumericSetting<bool>*>(Wiimote::GetWiimoteGroup(player, WiimoteEmu::WiimoteGroup::Options)->numeric_settings[3].get())->SetValue(_wmSideways[player]);
}

void DolHost::setWiimoteUpright (int player)
{
    static_cast<ControllerEmu::NumericSetting<bool>*>(Wiimote::GetWiimoteGroup(player, WiimoteEmu::WiimoteGroup::Options)->numeric_settings[2].get())->SetValue(_wmUpright[player]);
}

void DolHost::changeWiimoteExtension(int extension, int player)
{
    player -= 1;
    static_cast<ControllerEmu::Attachments*>(Wiimote::GetWiimoteGroup(player, WiimoteEmu::WiimoteGroup::Attachments))->SetSelectedAttachment(extension);
}

void DolHost::SetIR(int player, float x, float y)
{
    //setWiiIR(player, x,  y);
}

# pragma mark - DVD info

void DolHost::GetGameInfo()
{
    std::unique_ptr<DiscIO::Volume> pVolume = DiscIO::CreateVolume(_gamePath );
    
    _gameID = pVolume->GetGameID();
    _gameRegion = pVolume->GetRegion();
    _gameType =  pVolume->GetVolumeType();
    _gameCountry =  DiscIO::CountryCodeToCountry(_gameID[3], _gameType , _gameRegion);
    _gameName = pVolume -> GetInternalName();
    _gameCountryDir = GetDirOfCountry(_gameCountry);
    _gameType = pVolume->GetVolumeType();
}

float DolHost::GetFrameInterval()
{
    return DiscIO::IsNTSC(SConfig::GetInstance().m_region)  ? (60.0f / 1.001f) : 50.0f;
}

std::string DolHost::GetNameOfRegion(DiscIO::Region region)
{
    switch (region)
    {
            
        case DiscIO::Region::NTSC_J:
            return "NTSC_J";
            
        case DiscIO::Region::NTSC_U:
            return "NTSC_U";
            
        case DiscIO::Region::PAL:
            return "PAL";
            
        case DiscIO::Region::NTSC_K:
            return "NTSC_K";
            
        case DiscIO::Region::Unknown:
        default:
            return "";
    }
}

std::string DolHost::GetDirOfCountry(DiscIO::Country country)
{
    switch (country)
    {
        case DiscIO::Country::USA:
            return USA_DIR;
            
        case DiscIO::Country::Taiwan:
        case DiscIO::Country::Korea:
        case DiscIO::Country::Japan:
            return JAP_DIR;
            
        case DiscIO::Country::Australia:
        case DiscIO::Country::Europe:
        case DiscIO::Country::France:
        case DiscIO::Country::Germany:
        case DiscIO::Country::Italy:
        case DiscIO::Country::Netherlands:
        case DiscIO::Country::Russia:
        case DiscIO::Country::Spain:
        case DiscIO::Country::World:
            return EUR_DIR;
            
        case DiscIO::Country::Unknown:
        default:
            return "";
    }
}

WindowSystemInfo DolHost::GetWSI()
{
    return wsi;
}

# pragma mark - Dolphin Host callbacks
void Host_NotifyMapLoaded() {}
void Host_RefreshDSPDebuggerWindow() {}
void Host_Message(HostMessageID id) {}
void* Host_GetRenderHandle() { return (void *)-1; }
void Host_UpdateTitle(const std::string&) {}
void Host_UpdateDisasmDialog() {}
void Host_UpdateMainFrame() {}
void Host_RequestRenderWindowSize(int width, int height){}
void Host_SetStartupDebuggingParameters()
{
    SConfig& StartUp = SConfig::GetInstance();
    StartUp.bBootToPause = false;
}

std::vector<std::string> Host_GetPreferredLocales()
{
  return {};
}

bool Host_UINeedsControllerState(){ return false; }
bool Host_UIBlocksControllerState() { return false; }
bool Host_RendererHasFocus() { return true; }
bool Host_RendererHasFullFocus() { return true; }
bool Host_RendererIsFullscreen() { return false; }
void Host_ShowVideoConfig(void*, const std::string&) {}
void Host_YieldToUI() {}
void Host_TitleChanged() {}
void Host_UpdateProgressDialog(const char* caption, int position, int total) {}
void Host_PPCSymbolsChanged() {}
void Host_PPCBreakpointsChanged() {}
void Host_JitCacheInvalidation() {}
void Host_JitProfileDataWiped() {}
void Host_UpdateDiscordClientID(const std::string& client_id) {}
bool Host_UpdateDiscordPresenceRaw(const std::string& details, const std::string& state,
                                    const std::string& large_image_key,
                                    const std::string& large_image_text,
                                    const std::string& small_image_key,
                                    const std::string& small_image_text,
                                    const int64_t start_timestamp,
                                    const int64_t end_timestamp,
                                    const int party_size, const int party_max)
{
    return false;
}
bool Host_TASInputHasFocus() { return false; }
std::unique_ptr<GBAHostInterface> Host_CreateGBAHost(std::weak_ptr<HW::GBA::Core> core)
{
    return nullptr;
}
