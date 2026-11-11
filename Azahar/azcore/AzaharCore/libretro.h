/*
 * libretro.h -- minimal API header used by the OpenEmu/Azahar bridge.
 *
 * This header is vendored because the Azahar source archive supplied for this
 * project does not contain its libretro-common submodule. It intentionally
 * contains the ABI declarations and constants used by AzaharGameCore.mm.
 * The canonical full API header is maintained by libretro/libretro-common.
 */
#ifndef AZAHAR_OPENEMU_LIBRETRO_H
#define AZAHAR_OPENEMU_LIBRETRO_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef bool ( *retro_environment_t)(unsigned cmd, void *data);
typedef void (*retro_video_refresh_t)(const void *data, unsigned width, unsigned height, size_t pitch);
typedef void (*retro_audio_sample_t)(int16_t left, int16_t right);
typedef size_t (*retro_audio_sample_batch_t)(const int16_t *data, size_t frames);
typedef void (*retro_input_poll_t)(void);
typedef int16_t (*retro_input_state_t)(unsigned port, unsigned device, unsigned index, unsigned id);

enum retro_device {
    RETRO_DEVICE_NONE = 0,
    RETRO_DEVICE_JOYPAD = 1,
    RETRO_DEVICE_MOUSE = 2,
    RETRO_DEVICE_KEYBOARD = 3,
    RETRO_DEVICE_LIGHTGUN = 4,
    RETRO_DEVICE_ANALOG = 5,
    RETRO_DEVICE_POINTER = 6
};

enum retro_device_id_joypad {
    RETRO_DEVICE_ID_JOYPAD_B = 0,
    RETRO_DEVICE_ID_JOYPAD_Y = 1,
    RETRO_DEVICE_ID_JOYPAD_SELECT = 2,
    RETRO_DEVICE_ID_JOYPAD_START = 3,
    RETRO_DEVICE_ID_JOYPAD_UP = 4,
    RETRO_DEVICE_ID_JOYPAD_DOWN = 5,
    RETRO_DEVICE_ID_JOYPAD_LEFT = 6,
    RETRO_DEVICE_ID_JOYPAD_RIGHT = 7,
    RETRO_DEVICE_ID_JOYPAD_A = 8,
    RETRO_DEVICE_ID_JOYPAD_X = 9,
    RETRO_DEVICE_ID_JOYPAD_L = 10,
    RETRO_DEVICE_ID_JOYPAD_R = 11,
    RETRO_DEVICE_ID_JOYPAD_L2 = 12,
    RETRO_DEVICE_ID_JOYPAD_R2 = 13,
    RETRO_DEVICE_ID_JOYPAD_L3 = 14,
    RETRO_DEVICE_ID_JOYPAD_R3 = 15
};

enum retro_device_index_analog {
    RETRO_DEVICE_INDEX_ANALOG_LEFT = 0,
    RETRO_DEVICE_INDEX_ANALOG_RIGHT = 1
};

enum retro_device_id_analog {
    RETRO_DEVICE_ID_ANALOG_X = 0,
    RETRO_DEVICE_ID_ANALOG_Y = 1
};

enum retro_device_id_pointer {
    RETRO_DEVICE_ID_POINTER_X = 0,
    RETRO_DEVICE_ID_POINTER_Y = 1,
    RETRO_DEVICE_ID_POINTER_PRESSED = 2,
    RETRO_DEVICE_ID_POINTER_COUNT = 3,
    RETRO_DEVICE_ID_POINTER_IS_OFFSCREEN = 15
};

enum retro_device_id_mouse {
    RETRO_DEVICE_ID_MOUSE_X = 0,
    RETRO_DEVICE_ID_MOUSE_Y = 1,
    RETRO_DEVICE_ID_MOUSE_LEFT = 2,
    RETRO_DEVICE_ID_MOUSE_RIGHT = 3,
    RETRO_DEVICE_ID_MOUSE_WHEELUP = 4,
    RETRO_DEVICE_ID_MOUSE_WHEELDOWN = 5,
    RETRO_DEVICE_ID_MOUSE_MIDDLE = 6
};

enum retro_pixel_format {
    RETRO_PIXEL_FORMAT_0RGB1555 = 0,
    RETRO_PIXEL_FORMAT_XRGB8888 = 1,
    RETRO_PIXEL_FORMAT_RGB565 = 2
};

enum retro_hw_context_type {
    RETRO_HW_CONTEXT_NONE = 0,
    RETRO_HW_CONTEXT_OPENGL = 1,
    RETRO_HW_CONTEXT_OPENGLES2 = 2,
    RETRO_HW_CONTEXT_OPENGL_CORE = 3,
    RETRO_HW_CONTEXT_OPENGLES3 = 4,
    RETRO_HW_CONTEXT_OPENGLES_VERSION = 5,
    RETRO_HW_CONTEXT_VULKAN = 6,
    RETRO_HW_CONTEXT_D3D11 = 7,
    RETRO_HW_CONTEXT_D3D10 = 8,
    RETRO_HW_CONTEXT_D3D12 = 9,
    RETRO_HW_CONTEXT_D3D9 = 10,
    RETRO_HW_CONTEXT_D3D8 = 11,
    RETRO_HW_CONTEXT_METAL = 12
};

#define RETRO_ENVIRONMENT_EXPERIMENTAL 0x10000
#define RETRO_ENVIRONMENT_PRIVATE 0x20000
#define RETRO_ENVIRONMENT_SET_MESSAGE 6
#define RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY 9
#define RETRO_ENVIRONMENT_SET_PIXEL_FORMAT 10
#define RETRO_ENVIRONMENT_SET_INPUT_DESCRIPTORS 11
#define RETRO_ENVIRONMENT_SET_HW_RENDER 14
#define RETRO_ENVIRONMENT_GET_VARIABLE 15
#define RETRO_ENVIRONMENT_SET_VARIABLES 16
#define RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE 17
#define RETRO_ENVIRONMENT_GET_SENSOR_INTERFACE 25
#define RETRO_ENVIRONMENT_GET_LOG_INTERFACE 27
#define RETRO_ENVIRONMENT_GET_CONTENT_DIRECTORY 30
#define RETRO_ENVIRONMENT_GET_CORE_ASSETS_DIRECTORY 30
#define RETRO_ENVIRONMENT_SET_SERIALIZATION_QUIRKS 44
#define RETRO_ENVIRONMENT_SET_HW_SHARED_CONTEXT (44 | RETRO_ENVIRONMENT_EXPERIMENTAL)
#define RETRO_ENVIRONMENT_GET_CURRENT_SOFTWARE_FRAMEBUFFER (40 | RETRO_ENVIRONMENT_EXPERIMENTAL)
#define RETRO_ENVIRONMENT_GET_PREFERRED_HW_RENDER 49
#define RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY 31
#define RETRO_ENVIRONMENT_GET_MICROPHONE_INTERFACE 55
#define RETRO_ENVIRONMENT_SHUTDOWN 7
#define RETRO_ENVIRONMENT_SET_CONTROLLER_INFO 35
#define RETRO_ENVIRONMENT_SET_MEMORY_MAPS 36
#define RETRO_ENVIRONMENT_SET_GEOMETRY 37
#define RETRO_ENVIRONMENT_SET_CORE_OPTIONS_VERSION 52
#define RETRO_ENVIRONMENT_GET_CORE_OPTIONS_VERSION 52
#define RETRO_ENVIRONMENT_SET_CORE_OPTIONS 53
#define RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2 59
#define RETRO_ENVIRONMENT_SET_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE (43 | RETRO_ENVIRONMENT_EXPERIMENTAL)
#define RETRO_ENVIRONMENT_GET_HW_RENDER_INTERFACE (41 | RETRO_ENVIRONMENT_EXPERIMENTAL)
#define RETRO_ENVIRONMENT_GET_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE_SUPPORT (73 | RETRO_ENVIRONMENT_EXPERIMENTAL)

enum retro_memory_type {
    RETRO_MEMORY_MASK = 0xff,
    RETRO_MEMORY_SAVE_RAM = 0,
    RETRO_MEMORY_RTC = 1,
    RETRO_MEMORY_SYSTEM_RAM = 2,
    RETRO_MEMORY_VIDEO_RAM = 3,
    RETRO_MEMORY_ROM = 4
};

struct retro_message {
    const char *msg;
    unsigned frames;
};

struct retro_log_callback {
    void (*log)(int level, const char *fmt, ...);
};

struct retro_variable {
    const char *key;
    const char *value;
};

struct retro_game_info {
    const char *path;
    const void *data;
    size_t size;
    const char *meta;
};

struct retro_system_info {
    const char *library_name;
    const char *library_version;
    const char *valid_extensions;
    bool need_fullpath;
    bool block_extract;
};

struct retro_game_geometry {
    unsigned base_width;
    unsigned base_height;
    unsigned max_width;
    unsigned max_height;
    float aspect_ratio;
};

struct retro_system_timing {
    double fps;
    double sample_rate;
};

struct retro_system_av_info {
    struct retro_game_geometry geometry;
    struct retro_system_timing timing;
};

struct retro_framebuffer {
    void *data;
    unsigned width;
    unsigned height;
    size_t pitch;
    enum retro_pixel_format format;
    unsigned access_flags;
    unsigned memory_flags;
};

typedef void (*retro_init_t)(void);
typedef void (*retro_deinit_t)(void);
typedef unsigned (*retro_api_version_t)(void);
typedef void (*retro_get_system_info_t)(struct retro_system_info *);
typedef void (*retro_get_system_av_info_t)(struct retro_system_av_info *);
typedef void (*retro_set_environment_t)(retro_environment_t);
typedef void (*retro_set_video_refresh_t)(retro_video_refresh_t);
typedef void (*retro_set_audio_sample_t)(retro_audio_sample_t);
typedef void (*retro_set_audio_sample_batch_t)(retro_audio_sample_batch_t);
typedef void (*retro_set_input_poll_t)(retro_input_poll_t);
typedef void (*retro_set_input_state_t)(retro_input_state_t);
typedef void (*retro_set_controller_port_device_t)(unsigned port, unsigned device);
typedef bool (*retro_load_game_t)(const struct retro_game_info *game);
typedef void (*retro_unload_game_t)(void);
typedef void (*retro_run_t)(void);
typedef void (*retro_reset_t)(void);
typedef size_t (*retro_serialize_size_t)(void);
typedef bool (*retro_serialize_t)(void *data, size_t size);
typedef bool (*retro_unserialize_t)(const void *data, size_t size);
typedef bool (*retro_load_game_special_t)(unsigned type, const struct retro_game_info *info, size_t num);
typedef unsigned (*retro_get_region_t)(void);

#ifdef __cplusplus
}
#endif

#endif
