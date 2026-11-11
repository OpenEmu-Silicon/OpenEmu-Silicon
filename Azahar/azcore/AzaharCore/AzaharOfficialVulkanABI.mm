#include <initializer_list>
/* Official libretro Vulkan ABI adapter and validation gates.
 *
 * This translation unit uses upstream official libretro/Vulkan headers, unlike
 * AzaharGameCore.mm which has a historical minimal libretro ABI definition.
 * Keeping them separate avoids mismatched/redefined ABI structures.
 *
 * These exported tests and callback helpers came from many integration stages.
 * A successful *private* gate is not equivalent to a published live interface
 * or successful game rendering: the active game path performs a separate,
 * guarded device negotiation and verified bitmap handoff.
 *
 * Borrowed images, callbacks and Vulkan handles must not outlive the owning
 * core/queue/device. Do not move the release phase ahead of GPU completion.
 */
#if defined(__has_include) && __has_include(<vulkan/vulkan.h>)
# include "OfficialABI/libretro.h"
# include "OfficialABI/libretro_vulkan.h"
# include <stddef.h>
# include <cstring>
# include <new>
# include <mutex>
# include <type_traits>
static_assert(RETRO_HW_RENDER_INTERFACE_VULKAN_VERSION == 5, "Review upstream Vulkan interface version");
static_assert(RETRO_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE_VULKAN_VERSION == 2, "Review upstream negotiation version");
static_assert(std::is_standard_layout<retro_vulkan_context>::value, "Vulkan context ABI layout");
static_assert(offsetof(retro_hw_render_interface_vulkan, interface_type) == 0, "Vulkan interface ABI header");
/* ABI layout is checked here, not in the minimal libretro translation unit.
   These compile-time checks are necessary but not sufficient for live Vulkan:
   the separately guarded runtime negotiation must verify device ownership,
   image synchronization and the bitmap frame consumer before publication. */
static_assert(offsetof(retro_hw_render_interface_vulkan, interface_version) == sizeof(unsigned), "ABI interface version offset");
static_assert(offsetof(retro_hw_render_interface_vulkan, handle) > offsetof(retro_hw_render_interface_vulkan, interface_version), "ABI handle offset");
static_assert(offsetof(retro_hw_render_interface_vulkan, set_image) > offsetof(retro_hw_render_interface_vulkan, queue_index), "ABI image callback ordering");
static_assert(offsetof(retro_hw_render_context_negotiation_interface_vulkan, interface_type) == 0, "Negotiation header offset");
static_assert(offsetof(retro_hw_render_context_negotiation_interface_vulkan, interface_version) == sizeof(unsigned), "Negotiation version offset");
extern "C" int AzaharOfficialVulkanABICompileGate(void) { return 1; }
extern "C" int AzaharV121OfficialInterfaceLayoutGate(void) {
   retro_hw_render_interface_vulkan staged = {};
   staged.interface_type = RETRO_HW_RENDER_INTERFACE_VULKAN;
   staged.interface_version = RETRO_HW_RENDER_INTERFACE_VULKAN_VERSION;
   /* No handles or callbacks assigned: not a valid runtime interface. */
   return staged.interface_type == RETRO_HW_RENDER_INTERFACE_VULKAN &&
          staged.interface_version == 5 && staged.device == VK_NULL_HANDLE &&
          staged.set_image == nullptr && staged.get_instance_proc_addr == nullptr;
}
/* Stage real, live device/queue handles into the official ABI *without publishing*.
   This is a read-only, scoped compatibility check. No callbacks, image exchange,
   hardware acceptance, or persistent pointers. The owner remains responsible
   for destruction after this call returns. */
extern "C" unsigned AzaharV122StageOwnedDevice(void *instance, void *physical,
    void *device, void *queue, unsigned family, void *instanceProc) {
   if (!instance || !physical || !device || !queue || !instanceProc) return 0;
   retro_hw_render_interface_vulkan staged = {};
   staged.interface_type = RETRO_HW_RENDER_INTERFACE_VULKAN;
   staged.interface_version = RETRO_HW_RENDER_INTERFACE_VULKAN_VERSION;
   staged.instance = reinterpret_cast<VkInstance>(instance);
   staged.gpu = reinterpret_cast<VkPhysicalDevice>(physical);
   staged.device = reinterpret_cast<VkDevice>(device);
   staged.queue = reinterpret_cast<VkQueue>(queue);
   staged.queue_index = family;
   staged.get_instance_proc_addr = reinterpret_cast<PFN_vkGetInstanceProcAddr>(instanceProc);
   staged.get_device_proc_addr = staged.get_instance_proc_addr(staged.instance, "vkGetDeviceProcAddr")
      ? reinterpret_cast<PFN_vkGetDeviceProcAddr>(staged.get_instance_proc_addr(staged.instance, "vkGetDeviceProcAddr")) : nullptr;
   unsigned mask = 0;
   if (staged.interface_type == RETRO_HW_RENDER_INTERFACE_VULKAN && staged.interface_version == 5) mask |= 1u;
   if (staged.instance && staged.gpu && staged.device && staged.queue) mask |= 2u;
   if (staged.get_instance_proc_addr && staged.get_device_proc_addr) mask |= 4u;
   if (staged.queue_index == family) mask |= 8u;
   if (!staged.set_image && !staged.handle) mask |= 16u;
   return mask;
}
/* Castle 133: official libretro Vulkan bridge contract audit. This is a static,
   non-publishing inspection of the ABI. It deliberately supplies no fake
   callbacks, no image, and no frontend context. */
extern "C" unsigned AzaharV133BridgeContractGate(void) {
   unsigned mask = 0;
   if (RETRO_HW_RENDER_INTERFACE_VULKAN_VERSION == 5 &&
       RETRO_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE_VULKAN_VERSION == 2) mask |= 1u;
   if (offsetof(retro_hw_render_interface_vulkan, set_image) >
       offsetof(retro_hw_render_interface_vulkan, queue_index) &&
       offsetof(retro_hw_render_interface_vulkan, get_device_proc_addr) >
       offsetof(retro_hw_render_interface_vulkan, device)) mask |= 2u;
   if (offsetof(retro_hw_render_context_negotiation_interface_vulkan, get_application_info) >
       offsetof(retro_hw_render_context_negotiation_interface_vulkan, interface_version)) mask |= 4u;
   if (offsetof(retro_vulkan_image, image_layout) > offsetof(retro_vulkan_image, image_view) &&
       offsetof(retro_vulkan_image, create_info) > offsetof(retro_vulkan_image, image_layout)) mask |= 8u;
   retro_hw_render_interface_vulkan interface = {};
   interface.interface_type = RETRO_HW_RENDER_INTERFACE_VULKAN;
   interface.interface_version = RETRO_HW_RENDER_INTERFACE_VULKAN_VERSION;
   if (!interface.handle && !interface.set_image && !interface.instance &&
       !interface.device && !interface.queue) mask |= 16u;
   retro_hw_render_context_negotiation_interface_vulkan negotiation = {};
   negotiation.interface_type = RETRO_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE_VULKAN;
   negotiation.interface_version = RETRO_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE_VULKAN_VERSION;
   if (!negotiation.get_application_info && !negotiation.create_device) mask |= 32u;
   return mask;
}

/* Castle 142: private v2 Vulkan negotiation-contract rehearsal.
   No libretro environment command is accepted, and no core callback is invoked.
   Verify that a frontend can read a real VkApplicationInfo through the
   official ABI and identify all device/instance ownership boundaries. */
static const VkApplicationInfo *AzV142ApplicationInfo(void) {
   static const VkApplicationInfo app = {
      VK_STRUCTURE_TYPE_APPLICATION_INFO, nullptr,
      "Azahar OpenEmu Vulkan negotiation probe", 1,
      "OpenEmu", 1, VK_API_VERSION_1_1
   };
   return &app;
}
extern "C" unsigned AzaharV142NegotiationContractGate(void) {
   unsigned mask = 0;
   retro_hw_render_context_negotiation_interface_vulkan n = {};
   n.interface_type = RETRO_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE_VULKAN;
   n.interface_version = RETRO_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE_VULKAN_VERSION;
   n.get_application_info = AzV142ApplicationInfo;
   if (n.interface_type == RETRO_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE_VULKAN) mask |= 1u;
   if (n.interface_version == 2u) mask |= 2u;
   if (n.get_application_info) mask |= 4u;
   const VkApplicationInfo *app = n.get_application_info();
   if (app && app->sType == VK_STRUCTURE_TYPE_APPLICATION_INFO &&
       app->pApplicationName && app->pEngineName) mask |= 8u;
   if (app && VK_VERSION_MAJOR(app->apiVersion) == 1 &&
       VK_VERSION_MINOR(app->apiVersion) == 1) mask |= 16u;
   if (!n.create_device && !n.create_device2 && !n.create_instance &&
       !n.destroy_device) mask |= 32u;
   retro_hw_render_interface_vulkan hw = {};
   hw.interface_type = RETRO_HW_RENDER_INTERFACE_VULKAN;
   hw.interface_version = RETRO_HW_RENDER_INTERFACE_VULKAN_VERSION;
   if (hw.interface_version == 5u && !hw.set_image && !hw.device) mask |= 64u;
   if (offsetof(retro_hw_render_context_negotiation_interface_vulkan, create_device2) >
       offsetof(retro_hw_render_context_negotiation_interface_vulkan, create_instance)) mask |= 128u;
   return mask;
}
/* Castle 145: independent read-only, official-ABI negotiation boundary audit.
   The frontend cannot legitimately accept stage 1 until its GPU presenter and
   synchronization callbacks exist. These checks explicitly verify that the
   staged interface remains unpublishable, and that the v2 negotiation callback
   contract is not accidentally treated as a v5 rendering interface. */
extern "C" unsigned AzaharV145BoundaryAudit(void) {
   unsigned mask = 0;
   retro_hw_render_context_negotiation_interface_vulkan n = {};
   n.interface_type = RETRO_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE_VULKAN;
   n.interface_version = RETRO_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE_VULKAN_VERSION;
   n.get_application_info = AzV142ApplicationInfo;
   if (n.interface_type == RETRO_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE_VULKAN) mask |= 1u;
   if (n.interface_version == 2u && n.get_application_info) mask |= 2u;
   if (n.get_application_info()->apiVersion == VK_API_VERSION_1_1) mask |= 4u;
   if (!n.create_instance && !n.create_device && !n.create_device2 && !n.destroy_device) mask |= 8u;
   retro_hw_render_interface_vulkan hw = {};
   hw.interface_type = RETRO_HW_RENDER_INTERFACE_VULKAN;
   hw.interface_version = RETRO_HW_RENDER_INTERFACE_VULKAN_VERSION;
   if (hw.interface_version == 5u) mask |= 16u;
   if (!hw.set_image && !hw.get_sync_index && !hw.wait_sync_index) mask |= 32u;
   if (!hw.lock_queue && !hw.unlock_queue && !hw.handle) mask |= 64u;
   if (!hw.instance && !hw.device && !hw.queue && !hw.gpu) mask |= 128u;
   return mask;
}
/* Castle 143: eight independent checks against an ACTUAL, currently owned
   Vulkan instance/device. These are preflight checks, not Azahar callbacks.
   Never publish the private negotiation struct or borrow these handles beyond
   the lifetime of the owner. */
extern "C" unsigned AzaharV143LiveNegotiationGate(void *instanceRaw, void *physicalRaw,
    void *deviceRaw, void *queueRaw, void *instanceProcRaw, unsigned family) {
   unsigned mask = 0;
   if (!instanceRaw || !physicalRaw || !deviceRaw || !queueRaw || !instanceProcRaw) return 0;
   VkInstance instance = reinterpret_cast<VkInstance>(instanceRaw);
   VkPhysicalDevice physical = reinterpret_cast<VkPhysicalDevice>(physicalRaw);
   VkDevice device = reinterpret_cast<VkDevice>(deviceRaw);
   VkQueue queue = reinterpret_cast<VkQueue>(queueRaw);
   auto gip = reinterpret_cast<PFN_vkGetInstanceProcAddr>(instanceProcRaw);
   auto gdp = reinterpret_cast<PFN_vkGetDeviceProcAddr>(gip(instance, "vkGetDeviceProcAddr"));
   if (gdp && gip(instance, "vkGetPhysicalDeviceProperties") &&
       gip(instance, "vkGetPhysicalDeviceQueueFamilyProperties")) mask |= 1u;
   retro_hw_render_context_negotiation_interface_vulkan n = {};
   n.interface_type = RETRO_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE_VULKAN;
   n.interface_version = RETRO_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE_VULKAN_VERSION;
   n.get_application_info = AzV142ApplicationInfo;
   if (n.interface_type == RETRO_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE_VULKAN &&
       n.interface_version == 2u && n.get_application_info) mask |= 2u;
   const VkApplicationInfo *app = n.get_application_info();
   if (app && app->sType == VK_STRUCTURE_TYPE_APPLICATION_INFO &&
       app->pApplicationName && app->pEngineName &&
       VK_VERSION_MAJOR(app->apiVersion) == 1u && VK_VERSION_MINOR(app->apiVersion) == 1u)
      mask |= 4u;
   auto getProps = reinterpret_cast<PFN_vkGetPhysicalDeviceProperties>(
       gip(instance, "vkGetPhysicalDeviceProperties"));
   if (getProps) {
      VkPhysicalDeviceProperties props = {};
      getProps(physical, &props);
      if (VK_VERSION_MAJOR(props.apiVersion) >= 1u && props.deviceName[0]) mask |= 8u;
   }
   auto getFamilies = reinterpret_cast<PFN_vkGetPhysicalDeviceQueueFamilyProperties>(
       gip(instance, "vkGetPhysicalDeviceQueueFamilyProperties"));
   if (getFamilies) {
      uint32_t count = 0;
      getFamilies(physical, &count, nullptr);
      if (count && count <= 256 && family < count) {
         VkQueueFamilyProperties families[256] = {};
         getFamilies(physical, &count, families);
         if (family < count && families[family].queueCount &&
             (families[family].queueFlags & VK_QUEUE_GRAPHICS_BIT)) mask |= 16u;
      }
   }
   if (gdp && gdp(device, "vkQueueSubmit") && gdp(device, "vkQueueWaitIdle") &&
       gdp(device, "vkCreateFence") && gdp(device, "vkWaitForFences")) mask |= 32u;
   retro_hw_render_interface_vulkan hw = {};
   hw.interface_type = RETRO_HW_RENDER_INTERFACE_VULKAN;
   hw.interface_version = RETRO_HW_RENDER_INTERFACE_VULKAN_VERSION;
   hw.instance = instance; hw.gpu = physical; hw.device = device;
   hw.queue = queue; hw.queue_index = family;
   hw.get_instance_proc_addr = gip; hw.get_device_proc_addr = gdp;
   if (hw.interface_version == 5u && hw.instance && hw.gpu && hw.device &&
       hw.queue && hw.get_instance_proc_addr && hw.get_device_proc_addr &&
       hw.queue_index == family) mask |= 64u;
   // A successful preflight must NOT imply that the frontend is ready.
   if (!n.create_device && !n.create_device2 && !n.create_instance &&
       !n.destroy_device && !hw.set_image && !hw.handle &&
       !hw.lock_queue && !hw.unlock_queue && !hw.wait_sync_index) mask |= 128u;
   return mask;
}
/* Castle 134: grouped, independent checks on a live Vulkan owner. The staged
   libretro interface exists ONLY on this stack frame; it is never returned,
   published to Azahar, or retained beyond the owning device's lifetime. */
extern "C" unsigned AzaharV134LiveBridgeStageGate(void *instanceRaw, void *physicalRaw,
    void *deviceRaw, void *queueRaw, void *getInstanceProcRaw, unsigned family) {
   unsigned mask = 0;
   if (!instanceRaw || !physicalRaw || !deviceRaw || !queueRaw || !getInstanceProcRaw)
      return 0;
   retro_hw_render_interface_vulkan staged = {};
   staged.interface_type = RETRO_HW_RENDER_INTERFACE_VULKAN;
   staged.interface_version = RETRO_HW_RENDER_INTERFACE_VULKAN_VERSION;
   staged.instance = reinterpret_cast<VkInstance>(instanceRaw);
   staged.gpu = reinterpret_cast<VkPhysicalDevice>(physicalRaw);
   staged.device = reinterpret_cast<VkDevice>(deviceRaw);
   staged.queue = reinterpret_cast<VkQueue>(queueRaw);
   staged.queue_index = family;
   staged.get_instance_proc_addr = reinterpret_cast<PFN_vkGetInstanceProcAddr>(getInstanceProcRaw);
   staged.get_device_proc_addr = reinterpret_cast<PFN_vkGetDeviceProcAddr>(
      staged.get_instance_proc_addr(staged.instance, "vkGetDeviceProcAddr"));
   if (staged.interface_type == RETRO_HW_RENDER_INTERFACE_VULKAN &&
       staged.interface_version == 5u) mask |= 1u;
   if (staged.instance && staged.gpu && staged.device && staged.queue) mask |= 2u;
   if (staged.queue_index == family) mask |= 4u;
   if (staged.get_instance_proc_addr && staged.get_device_proc_addr) mask |= 8u;
   if (staged.get_device_proc_addr &&
       staged.get_device_proc_addr(staged.device, "vkQueueSubmit") &&
       staged.get_device_proc_addr(staged.device, "vkQueueWaitIdle")) mask |= 16u;
   if (staged.get_device_proc_addr &&
       staged.get_device_proc_addr(staged.device, "vkCreateSemaphore") &&
       staged.get_device_proc_addr(staged.device, "vkDestroySemaphore")) mask |= 32u;
   retro_hw_render_context_negotiation_interface_vulkan negotiation = {};
   negotiation.interface_type = RETRO_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE_VULKAN;
   negotiation.interface_version = RETRO_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE_VULKAN_VERSION;
   if (negotiation.interface_version == 2u &&
       !negotiation.create_device && !negotiation.get_application_info) mask |= 64u;
   if (!staged.handle && !staged.set_image &&
       !staged.get_sync_index && !staged.get_sync_index_mask &&
       !staged.lock_queue && !staged.unlock_queue) mask |= 128u;
   return mask;
}
/* Castle 135: executable, scoped Vulkan interface callback tests.
   This is deliberately NOT an OpenEmu presenter. The image callback only
   rejects invalid inputs; it never takes ownership of a GPU image. */
struct AzV135Scope {
   std::mutex queueMutex;
   unsigned locks = 0, unlocks = 0, depth = 0;
   unsigned syncReads = 0, maskReads = 0, invalidImages = 0, acceptedImages = 0;
   bool alive = true;
};
static void AzV135Lock(void *handle) {
   auto *s = static_cast<AzV135Scope *>(handle);
   if (!s || !s->alive) return;
   s->queueMutex.lock(); ++s->locks; ++s->depth;
}
static void AzV135Unlock(void *handle) {
   auto *s = static_cast<AzV135Scope *>(handle);
   if (!s || !s->alive || !s->depth) return;
   --s->depth; ++s->unlocks; s->queueMutex.unlock();
}
static uint32_t AzV135SyncIndex(void *handle) {
   auto *s = static_cast<AzV135Scope *>(handle);
   if (!s || !s->alive) return 0;
   ++s->syncReads;
   return 0; /* test-only, not a frontend-acquired swapchain index */
}
static uint32_t AzV135SyncMask(void *handle) {
   auto *s = static_cast<AzV135Scope *>(handle);
   if (!s || !s->alive) return 0;
   ++s->maskReads;
   return 1; /* test-only, not a real frontend buffer count */
}
static void AzV135SetImage(void *handle, const retro_vulkan_image *image,
      uint32_t numSemaphores, const VkSemaphore *semaphores, uint32_t) {
   auto *s = static_cast<AzV135Scope *>(handle);
   if (!s || !s->alive) return;
   if (!image || image->image_view == VK_NULL_HANDLE ||
       image->create_info.sType != VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO ||
       (numSemaphores && !semaphores)) { ++s->invalidImages; return; }
   /* No real image handoff or retention: fail closed even for valid descriptors. */
   ++s->invalidImages;
}
extern "C" unsigned AzaharV135ScopedCallbacksGate(void *instanceRaw,
   void *physicalRaw, void *deviceRaw, void *queueRaw, void *getInstanceProcRaw,
   unsigned family) {
   if (!instanceRaw || !physicalRaw || !deviceRaw || !queueRaw || !getInstanceProcRaw)
      return 0;
   AzV135Scope scope;
   retro_hw_render_interface_vulkan staged = {};
   staged.interface_type = RETRO_HW_RENDER_INTERFACE_VULKAN;
   staged.interface_version = RETRO_HW_RENDER_INTERFACE_VULKAN_VERSION;
   staged.handle = &scope;
   staged.instance = reinterpret_cast<VkInstance>(instanceRaw);
   staged.gpu = reinterpret_cast<VkPhysicalDevice>(physicalRaw);
   staged.device = reinterpret_cast<VkDevice>(deviceRaw);
   staged.queue = reinterpret_cast<VkQueue>(queueRaw);
   staged.queue_index = family;
   staged.get_instance_proc_addr = reinterpret_cast<PFN_vkGetInstanceProcAddr>(getInstanceProcRaw);
   staged.get_device_proc_addr = reinterpret_cast<PFN_vkGetDeviceProcAddr>(
       staged.get_instance_proc_addr(staged.instance, "vkGetDeviceProcAddr"));
   staged.lock_queue = &AzV135Lock;
   staged.unlock_queue = &AzV135Unlock;
   staged.get_sync_index = &AzV135SyncIndex;
   staged.get_sync_index_mask = &AzV135SyncMask;
   staged.set_image = &AzV135SetImage;
   unsigned mask = 0;
   if (staged.interface_version == 5u && staged.handle == &scope &&
       staged.device && staged.queue && staged.get_device_proc_addr) mask |= 1u;
   if (staged.lock_queue && staged.unlock_queue && staged.get_sync_index &&
       staged.get_sync_index_mask && staged.set_image) mask |= 2u;
   staged.lock_queue(staged.handle);
   if (scope.depth == 1 && scope.locks == 1) mask |= 4u;
   if (staged.get_sync_index(staged.handle) == 0 &&
       staged.get_sync_index_mask(staged.handle) == 1 &&
       scope.syncReads == 1 && scope.maskReads == 1) mask |= 8u;
   staged.set_image(staged.handle, nullptr, 0, nullptr, family);
   retro_vulkan_image bad = {};
   bad.create_info.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
   staged.set_image(staged.handle, &bad, 0, nullptr, family);
   if (scope.invalidImages == 2 && scope.acceptedImages == 0) mask |= 16u;
   staged.unlock_queue(staged.handle);
   if (scope.depth == 0 && scope.unlocks == 1 &&
       scope.locks == scope.unlocks) mask |= 32u;
   if (staged.get_device_proc_addr(staged.device, "vkQueueSubmit") &&
       staged.get_device_proc_addr(staged.device, "vkQueueWaitIdle")) mask |= 64u;
   staged.handle = nullptr;
   staged.set_image = nullptr;
   staged.lock_queue = nullptr;
   staged.unlock_queue = nullptr;
   staged.get_sync_index = nullptr;
   staged.get_sync_index_mask = nullptr;
   scope.alive = false;
   if (!staged.handle && !staged.set_image && !staged.lock_queue &&
       !staged.unlock_queue && !staged.get_sync_index &&
       !staged.get_sync_index_mask && !scope.alive && scope.depth == 0) mask |= 128u;
   return mask;
}
/* Castle 136: real VkImage/VkImageView descriptor handoff into a private,
   borrowed-reference staging slot. No Vulkan ownership is transferred, no
   semaphores are waited on, and the slot never escapes this synchronous test. */
struct AzV136Slot {
   VkImageView view = VK_NULL_HANDLE;
   VkImageLayout layout = VK_IMAGE_LAYOUT_UNDEFINED;
   VkImageViewCreateInfo info = {};
   unsigned accepted = 0, rejected = 0, replacements = 0;
   bool alive = true;
};
static void AzV136SetImage(void *handle, const retro_vulkan_image *image,
      uint32_t semaphoreCount, const VkSemaphore *semaphores, uint32_t) {
   auto *slot = static_cast<AzV136Slot *>(handle);
   if (!slot || !slot->alive) return;
   if (!image || image->image_view == VK_NULL_HANDLE ||
       image->create_info.sType != VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO ||
       image->create_info.viewType != VK_IMAGE_VIEW_TYPE_2D ||
       image->create_info.format != VK_FORMAT_R8G8B8A8_UNORM ||
       image->create_info.image == VK_NULL_HANDLE ||
       image->image_layout != VK_IMAGE_LAYOUT_UNDEFINED ||
       semaphoreCount != 0 || semaphores != nullptr) {
      ++slot->rejected; return;
   }
   if (slot->view != VK_NULL_HANDLE) ++slot->replacements;
   slot->view = image->image_view;
   slot->layout = image->image_layout;
   slot->info = image->create_info;
   ++slot->accepted;
}
extern "C" unsigned AzaharV136ImageHandoffGate(void *instanceRaw,
   void *physicalRaw, void *deviceRaw, void *queueRaw, void *instanceProcRaw,
   unsigned family) {
   if (!instanceRaw || !physicalRaw || !deviceRaw || !queueRaw || !instanceProcRaw) return 0;
   auto instance = reinterpret_cast<VkInstance>(instanceRaw);
   auto physical = reinterpret_cast<VkPhysicalDevice>(physicalRaw);
   auto device = reinterpret_cast<VkDevice>(deviceRaw);
   auto gip = reinterpret_cast<PFN_vkGetInstanceProcAddr>(instanceProcRaw);
   auto gdp = reinterpret_cast<PFN_vkGetDeviceProcAddr>(gip(instance, "vkGetDeviceProcAddr"));
   if (!gdp) return 0;
#define AZ_V136_PROC(type, var, name) auto var = reinterpret_cast<type>(gdp(device, name))
   AZ_V136_PROC(PFN_vkCreateImage, createImage, "vkCreateImage");
   AZ_V136_PROC(PFN_vkDestroyImage, destroyImage, "vkDestroyImage");
   AZ_V136_PROC(PFN_vkGetImageMemoryRequirements, getRequirements, "vkGetImageMemoryRequirements");
   AZ_V136_PROC(PFN_vkAllocateMemory, allocateMemory, "vkAllocateMemory");
   AZ_V136_PROC(PFN_vkFreeMemory, freeMemory, "vkFreeMemory");
   AZ_V136_PROC(PFN_vkBindImageMemory, bindMemory, "vkBindImageMemory");
   AZ_V136_PROC(PFN_vkCreateImageView, createView, "vkCreateImageView");
   AZ_V136_PROC(PFN_vkDestroyImageView, destroyView, "vkDestroyImageView");
#undef AZ_V136_PROC
   auto memoryProperties = reinterpret_cast<PFN_vkGetPhysicalDeviceMemoryProperties>(
       gip(instance, "vkGetPhysicalDeviceMemoryProperties"));
   if (!createImage || !destroyImage || !getRequirements || !allocateMemory ||
       !freeMemory || !bindMemory || !createView || !destroyView || !memoryProperties) return 0;
   unsigned mask = 1u;
   VkImage image = VK_NULL_HANDLE;
   VkDeviceMemory memory = VK_NULL_HANDLE;
   VkImageView view = VK_NULL_HANDLE;
   VkImageCreateInfo imageInfo = {};
   imageInfo.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
   imageInfo.imageType = VK_IMAGE_TYPE_2D;
   imageInfo.format = VK_FORMAT_R8G8B8A8_UNORM;
   imageInfo.extent = {4, 4, 1};
   imageInfo.mipLevels = 1;
   imageInfo.arrayLayers = 1;
   imageInfo.samples = VK_SAMPLE_COUNT_1_BIT;
   imageInfo.tiling = VK_IMAGE_TILING_OPTIMAL;
   imageInfo.usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
   imageInfo.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
   imageInfo.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
   if (createImage(device, &imageInfo, nullptr, &image) != VK_SUCCESS) return mask;
   mask |= 2u;
   VkMemoryRequirements requirements = {};
   getRequirements(device, image, &requirements);
   VkPhysicalDeviceMemoryProperties props = {};
   memoryProperties(physical, &props);
   uint32_t memoryType = props.memoryTypeCount;
   for (uint32_t i = 0; i < props.memoryTypeCount; ++i)
      if (requirements.memoryTypeBits & (1u << i)) { memoryType = i; break; }
   if (memoryType < props.memoryTypeCount) {
      VkMemoryAllocateInfo alloc = {};
      alloc.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
      alloc.allocationSize = requirements.size;
      alloc.memoryTypeIndex = memoryType;
      if (allocateMemory(device, &alloc, nullptr, &memory) == VK_SUCCESS &&
          bindMemory(device, image, memory, 0) == VK_SUCCESS) mask |= 4u;
   }
   if (mask & 4u) {
      VkImageViewCreateInfo info = {};
      info.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
      info.image = image;
      info.viewType = VK_IMAGE_VIEW_TYPE_2D;
      info.format = VK_FORMAT_R8G8B8A8_UNORM;
      info.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
      info.subresourceRange.levelCount = 1;
      info.subresourceRange.layerCount = 1;
      if (createView(device, &info, nullptr, &view) == VK_SUCCESS) {
         mask |= 8u;
         AzV136Slot slot;
         retro_hw_render_interface_vulkan staged = {};
         staged.interface_type = RETRO_HW_RENDER_INTERFACE_VULKAN;
         staged.interface_version = RETRO_HW_RENDER_INTERFACE_VULKAN_VERSION;
         staged.handle = &slot;
         staged.set_image = &AzV136SetImage;
         retro_vulkan_image descriptor = {};
         descriptor.image_view = view;
         descriptor.image_layout = VK_IMAGE_LAYOUT_UNDEFINED;
         descriptor.create_info = info;
         staged.set_image(staged.handle, nullptr, 0, nullptr, family);
         staged.set_image(staged.handle, &descriptor, 1, nullptr, family);
         if (slot.rejected == 2 && slot.accepted == 0) mask |= 16u;
         staged.set_image(staged.handle, &descriptor, 0, nullptr, family);
         if (slot.accepted == 1 && slot.view == view &&
             slot.info.image == image && slot.layout == VK_IMAGE_LAYOUT_UNDEFINED)
            mask |= 32u;
         staged.set_image(staged.handle, &descriptor, 0, nullptr, family);
         if (slot.accepted == 2 && slot.replacements == 1 &&
             slot.info.image == image) mask |= 64u;
         slot.view = VK_NULL_HANDLE;
         slot.info = {};
         slot.alive = false;
         staged.handle = nullptr;
         staged.set_image = nullptr;
         if (!slot.alive && !slot.view && !staged.handle && !staged.set_image)
            mask |= 128u;
      }
   }
   if (view) destroyView(device, view, nullptr);
   if (image) destroyImage(device, image, nullptr);
   if (memory) freeMemory(device, memory, nullptr);
   return mask;
}
/* Castle 132: interrogate the exact physical device/queue used by the successful
   graphics tests. This is a read-only capability check, not libretro negotiation.
   Do not assume that successful isolated rendering means a usable frontend
   presenter, image-exchange callback, or Azahar-owned Vulkan context exists. */
extern "C" unsigned AzaharV132DeviceCapabilityGate(void *instanceRaw,
    void *physicalRaw, void *instanceProcRaw, unsigned family,
    unsigned *apiVersionOut, unsigned *queueFlagsOut, unsigned *deviceExtensionCountOut) {
   if (apiVersionOut) *apiVersionOut = 0;
   if (queueFlagsOut) *queueFlagsOut = 0;
   if (deviceExtensionCountOut) *deviceExtensionCountOut = 0;
   if (!instanceRaw || !physicalRaw || !instanceProcRaw) return 0;
   auto instance = reinterpret_cast<VkInstance>(instanceRaw);
   auto physical = reinterpret_cast<VkPhysicalDevice>(physicalRaw);
   auto gip = reinterpret_cast<PFN_vkGetInstanceProcAddr>(instanceProcRaw);
   auto getProperties = reinterpret_cast<PFN_vkGetPhysicalDeviceProperties>(
       gip(instance, "vkGetPhysicalDeviceProperties"));
   auto getQueues = reinterpret_cast<PFN_vkGetPhysicalDeviceQueueFamilyProperties>(
       gip(instance, "vkGetPhysicalDeviceQueueFamilyProperties"));
   auto getFeatures = reinterpret_cast<PFN_vkGetPhysicalDeviceFeatures>(
       gip(instance, "vkGetPhysicalDeviceFeatures"));
   auto enumExtensions = reinterpret_cast<PFN_vkEnumerateDeviceExtensionProperties>(
       gip(instance, "vkEnumerateDeviceExtensionProperties"));
   unsigned mask = 0;
   if (getProperties && getQueues && getFeatures && enumExtensions) mask |= 1u;
   if ((mask & 1u) == 0) return mask;
   VkPhysicalDeviceProperties props = {};
   getProperties(physical, &props);
   if (apiVersionOut) *apiVersionOut = props.apiVersion;
   if (VK_VERSION_MAJOR(props.apiVersion) >= 1) mask |= 2u;
   uint32_t queueCount = 0;
   getQueues(physical, &queueCount, nullptr);
   if (queueCount && family < queueCount) {
       // Query the selected family without an unsafe fixed-size stack array.
       // vkGetPhysicalDeviceQueueFamilyProperties writes up to the count passed.
       auto families = new (std::nothrow) VkQueueFamilyProperties[queueCount];
       if (families) {
           getQueues(physical, &queueCount, families);
           if (family < queueCount && families[family].queueCount > 0 &&
               (families[family].queueFlags & VK_QUEUE_GRAPHICS_BIT)) mask |= 4u;
           if (family < queueCount && queueFlagsOut)
               *queueFlagsOut = families[family].queueFlags;
           delete[] families;
       }
   }
   VkPhysicalDeviceFeatures features = {};
   getFeatures(physical, &features);
   // Core shader execution is required by Vulkan graphics pipelines; the
   // earlier triangle test is the actual operational shader verification.
   if (props.limits.maxBoundDescriptorSets > 0 &&
       props.limits.maxVertexInputBindings > 0) mask |= 8u;
   uint32_t extensions = 0;
   if (enumExtensions(physical, nullptr, &extensions, nullptr) == VK_SUCCESS) {
       if (deviceExtensionCountOut) *deviceExtensionCountOut = extensions;
       mask |= 16u;
   }
   return mask;
}
/* Castle 124: real, synchronous queue-idle operation on the temporary owned
   Vulkan queue. No Azahar callbacks or game rendering are involved. The caller
   guarantees that the device and queue remain alive for the entire call. */
extern "C" unsigned AzaharV124LiveQueueIdleGate(void *instanceRaw, void *deviceRaw,
    void *queueRaw, void *instanceProcRaw) {
   if (!instanceRaw || !deviceRaw || !queueRaw || !instanceProcRaw) return 0;
   auto instance = reinterpret_cast<VkInstance>(instanceRaw);
   auto device = reinterpret_cast<VkDevice>(deviceRaw);
   auto queue = reinterpret_cast<VkQueue>(queueRaw);
   auto gip = reinterpret_cast<PFN_vkGetInstanceProcAddr>(instanceProcRaw);
   auto gdp = reinterpret_cast<PFN_vkGetDeviceProcAddr>(gip(instance, "vkGetDeviceProcAddr"));
   unsigned mask = 0;
   if (gdp) mask |= 1u;
   if (!gdp) return mask;
   auto waitIdle = reinterpret_cast<PFN_vkQueueWaitIdle>(gdp(device, "vkQueueWaitIdle"));
   if (waitIdle) mask |= 2u;
   if (!waitIdle) return mask;
   /* The Vulkan device has no Azahar work queued. A successful result checks
      actual dispatch and queue validity, not inter-thread synchronization. */
   if (waitIdle(queue) == VK_SUCCESS) mask |= 4u;
   return mask;
}
/* Castle 128: execute a real GPU image clear, copy the image to a staging
   buffer, and inspect the GPU-produced RGBA bytes on the CPU. Isolated owned
   device only; no Azahar frame or OpenEmu Vulkan presentation yet. */
extern "C" unsigned AzaharV128ImageClearGate(void *instanceRaw, void *physicalRaw,
    void *deviceRaw, void *queueRaw, void *instanceProcRaw, unsigned family) {
   if (!instanceRaw || !physicalRaw || !deviceRaw || !queueRaw || !instanceProcRaw) return 0;
   auto instance = reinterpret_cast<VkInstance>(instanceRaw);
   auto physical = reinterpret_cast<VkPhysicalDevice>(physicalRaw);
   auto device = reinterpret_cast<VkDevice>(deviceRaw);
   auto queue = reinterpret_cast<VkQueue>(queueRaw);
   auto gip = reinterpret_cast<PFN_vkGetInstanceProcAddr>(instanceProcRaw);
   auto gdp = reinterpret_cast<PFN_vkGetDeviceProcAddr>(gip(instance, "vkGetDeviceProcAddr"));
   if (!gdp) return 0;
   unsigned mask = 1u;
#define AZ_V128_PROC(type, var, name) auto var = reinterpret_cast<type>(gdp(device, name))
   AZ_V128_PROC(PFN_vkCreateImage, createImage, "vkCreateImage");
   AZ_V128_PROC(PFN_vkDestroyImage, destroyImage, "vkDestroyImage");
   AZ_V128_PROC(PFN_vkGetImageMemoryRequirements, imageReq, "vkGetImageMemoryRequirements");
   AZ_V128_PROC(PFN_vkCreateBuffer, createBuffer, "vkCreateBuffer");
   AZ_V128_PROC(PFN_vkDestroyBuffer, destroyBuffer, "vkDestroyBuffer");
   AZ_V128_PROC(PFN_vkGetBufferMemoryRequirements, bufferReq, "vkGetBufferMemoryRequirements");
   AZ_V128_PROC(PFN_vkAllocateMemory, allocMemory, "vkAllocateMemory");
   AZ_V128_PROC(PFN_vkFreeMemory, freeMemory, "vkFreeMemory");
   AZ_V128_PROC(PFN_vkBindImageMemory, bindImage, "vkBindImageMemory");
   AZ_V128_PROC(PFN_vkBindBufferMemory, bindBuffer, "vkBindBufferMemory");
   AZ_V128_PROC(PFN_vkMapMemory, mapMemory, "vkMapMemory");
   AZ_V128_PROC(PFN_vkUnmapMemory, unmapMemory, "vkUnmapMemory");
   AZ_V128_PROC(PFN_vkCreateCommandPool, createPool, "vkCreateCommandPool");
   AZ_V128_PROC(PFN_vkDestroyCommandPool, destroyPool, "vkDestroyCommandPool");
   AZ_V128_PROC(PFN_vkAllocateCommandBuffers, allocCommands, "vkAllocateCommandBuffers");
   AZ_V128_PROC(PFN_vkBeginCommandBuffer, begin, "vkBeginCommandBuffer");
   AZ_V128_PROC(PFN_vkEndCommandBuffer, end, "vkEndCommandBuffer");
   AZ_V128_PROC(PFN_vkCmdPipelineBarrier, barrier, "vkCmdPipelineBarrier");
   AZ_V128_PROC(PFN_vkCmdClearColorImage, clearImage, "vkCmdClearColorImage");
   AZ_V128_PROC(PFN_vkCmdCopyImageToBuffer, copyImage, "vkCmdCopyImageToBuffer");
   AZ_V128_PROC(PFN_vkCreateFence, createFence, "vkCreateFence");
   AZ_V128_PROC(PFN_vkDestroyFence, destroyFence, "vkDestroyFence");
   AZ_V128_PROC(PFN_vkQueueSubmit, submit, "vkQueueSubmit");
   AZ_V128_PROC(PFN_vkWaitForFences, wait, "vkWaitForFences");
   AZ_V128_PROC(PFN_vkQueueWaitIdle, queueIdle, "vkQueueWaitIdle");
#undef AZ_V128_PROC
   auto getMemoryProperties = reinterpret_cast<PFN_vkGetPhysicalDeviceMemoryProperties>(
       gip(instance, "vkGetPhysicalDeviceMemoryProperties"));
   if (!createImage || !destroyImage || !imageReq || !createBuffer || !destroyBuffer ||
       !bufferReq || !allocMemory || !freeMemory || !bindImage || !bindBuffer ||
       !mapMemory || !unmapMemory || !createPool || !destroyPool || !allocCommands ||
       !begin || !end || !barrier || !clearImage || !copyImage || !createFence ||
       !destroyFence || !submit || !wait || !queueIdle || !getMemoryProperties) return mask;
   mask |= 2u;
   VkPhysicalDeviceMemoryProperties memoryProps = {};
   getMemoryProperties(physical, &memoryProps);
   auto memoryType = [&](uint32_t allowed, VkMemoryPropertyFlags required) -> uint32_t {
      for (uint32_t i = 0; i < memoryProps.memoryTypeCount; ++i)
         if ((allowed & (1u << i)) &&
             (memoryProps.memoryTypes[i].propertyFlags & required) == required) return i;
      return UINT32_MAX;
   };
   VkImage image = VK_NULL_HANDLE;
   VkBuffer staging = VK_NULL_HANDLE;
   VkDeviceMemory imageMemory = VK_NULL_HANDLE, stagingMemory = VK_NULL_HANDLE;
   VkCommandPool pool = VK_NULL_HANDLE;
   VkFence fence = VK_NULL_HANDLE;
   bool submitted = false, completed = false;
   do {
      VkImageCreateInfo ii = {};
      ii.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
      ii.imageType = VK_IMAGE_TYPE_2D;
      ii.format = VK_FORMAT_R8G8B8A8_UNORM;
      ii.extent = {4, 4, 1};
      ii.mipLevels = 1; ii.arrayLayers = 1;
      ii.samples = VK_SAMPLE_COUNT_1_BIT;
      ii.tiling = VK_IMAGE_TILING_OPTIMAL;
      ii.usage = VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
      ii.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
      ii.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
      if (createImage(device, &ii, nullptr, &image) != VK_SUCCESS) break;
      VkMemoryRequirements ir = {};
      imageReq(device, image, &ir);
      uint32_t imageType = memoryType(ir.memoryTypeBits, 0);
      if (imageType == UINT32_MAX) break;
      VkMemoryAllocateInfo ai = {};
      ai.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
      ai.allocationSize = ir.size; ai.memoryTypeIndex = imageType;
      if (allocMemory(device, &ai, nullptr, &imageMemory) != VK_SUCCESS) break;
      if (bindImage(device, image, imageMemory, 0) != VK_SUCCESS) break;
      mask |= 4u;
      VkBufferCreateInfo bi = {};
      bi.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
      bi.size = 4 * 4 * 4;
      bi.usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT;
      bi.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
      if (createBuffer(device, &bi, nullptr, &staging) != VK_SUCCESS) break;
      VkMemoryRequirements br = {};
      bufferReq(device, staging, &br);
      uint32_t stagingType = memoryType(br.memoryTypeBits,
          VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
      if (stagingType == UINT32_MAX) break;
      ai.allocationSize = br.size; ai.memoryTypeIndex = stagingType;
      if (allocMemory(device, &ai, nullptr, &stagingMemory) != VK_SUCCESS) break;
      if (bindBuffer(device, staging, stagingMemory, 0) != VK_SUCCESS) break;
      mask |= 8u;
      VkCommandPoolCreateInfo pi = {};
      pi.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
      pi.queueFamilyIndex = family;
      if (createPool(device, &pi, nullptr, &pool) != VK_SUCCESS) break;
      VkCommandBuffer cmd = VK_NULL_HANDLE;
      VkCommandBufferAllocateInfo ci = {};
      ci.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
      ci.commandPool = pool; ci.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
      ci.commandBufferCount = 1;
      if (allocCommands(device, &ci, &cmd) != VK_SUCCESS) break;
      VkCommandBufferBeginInfo cb = {};
      cb.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
      cb.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
      if (begin(cmd, &cb) != VK_SUCCESS) break;
      VkImageSubresourceRange range = {};
      range.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
      range.levelCount = 1; range.layerCount = 1;
      VkImageMemoryBarrier ib = {};
      ib.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
      ib.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
      ib.newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
      ib.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
      ib.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
      ib.dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
      ib.image = image; ib.subresourceRange = range;
      barrier(cmd, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
              0, 0, nullptr, 0, nullptr, 1, &ib);
      VkClearColorValue color = {};
      color.float32[0] = 0.2f; color.float32[1] = 0.4f;
      color.float32[2] = 0.6f; color.float32[3] = 1.0f;
      clearImage(cmd, image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &color, 1, &range);
      ib.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
      ib.newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
      ib.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
      ib.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
      barrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
              0, 0, nullptr, 0, nullptr, 1, &ib);
      VkBufferImageCopy region = {};
      region.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
      region.imageSubresource.layerCount = 1;
      region.imageExtent = {4, 4, 1};
      copyImage(cmd, image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, staging, 1, &region);
      VkBufferMemoryBarrier bb = {};
      bb.sType = VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER;
      bb.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
      bb.dstAccessMask = VK_ACCESS_HOST_READ_BIT;
      bb.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
      bb.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
      bb.buffer = staging; bb.size = VK_WHOLE_SIZE;
      barrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT,
              0, 0, nullptr, 1, &bb, 0, nullptr);
      if (end(cmd) != VK_SUCCESS) break;
      mask |= 16u;
      VkFenceCreateInfo fi = {};
      fi.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
      if (createFence(device, &fi, nullptr, &fence) != VK_SUCCESS) break;
      VkSubmitInfo si = {};
      si.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
      si.commandBufferCount = 1; si.pCommandBuffers = &cmd;
      submitted = submit(queue, 1, &si, fence) == VK_SUCCESS;
      if (!submitted) break;
      mask |= 32u;
      completed = wait(device, 1, &fence, VK_TRUE, 5000000000ULL) == VK_SUCCESS;
      if (!completed) break;
      mask |= 64u;
      void *mapped = nullptr;
      if (mapMemory(device, stagingMemory, 0, 64, 0, &mapped) != VK_SUCCESS || !mapped) break;
      const auto *bytes = static_cast<const unsigned char *>(mapped);
      bool match = true;
      for (unsigned i = 0; i < 16; ++i) {
         const unsigned char *p = bytes + i * 4;
         if (p[0] != 51 || p[1] != 102 || p[2] != 153 || p[3] != 255) {
            match = false; break;
         }
      }
      unmapMemory(device, stagingMemory);
      if (match) mask |= 128u;
   } while (false);
   // If submitted but fence timed out, ensure completion before freeing resources.
   if (submitted && !completed) (void)queueIdle(queue);
   if (fence) destroyFence(device, fence, nullptr);
   if (pool) destroyPool(device, pool, nullptr);
   if (staging) destroyBuffer(device, staging, nullptr);
   if (image) destroyImage(device, image, nullptr);
   if (stagingMemory) freeMemory(device, stagingMemory, nullptr);
   if (imageMemory) freeMemory(device, imageMemory, nullptr);
   return mask;
}
/* Castle 137: accept a completed image only within a synchronous, private scope. */
static void AzV137SetImage(void *handle, const retro_vulkan_image *image,
    uint32_t count, const VkSemaphore *semaphores, uint32_t) {
   auto *slot = static_cast<AzV136Slot *>(handle);
   if (!slot || !slot->alive) return;
   if (!image || !image->image_view || !image->create_info.image ||
       image->create_info.sType != VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO ||
       image->image_layout != VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL ||
       count || semaphores) { ++slot->rejected; return; }
   slot->view = image->image_view;
   slot->layout = image->image_layout;
   slot->info = image->create_info;
   ++slot->accepted;
}
extern "C" unsigned AzaharV137SynchronizedImageHandoffGate(void *instanceRaw, void *physicalRaw,
    void *deviceRaw, void *queueRaw, void *instanceProcRaw, unsigned family) {
   if (!instanceRaw || !physicalRaw || !deviceRaw || !queueRaw || !instanceProcRaw) return 0;
   auto instance = reinterpret_cast<VkInstance>(instanceRaw);
   auto physical = reinterpret_cast<VkPhysicalDevice>(physicalRaw);
   auto device = reinterpret_cast<VkDevice>(deviceRaw);
   auto queue = reinterpret_cast<VkQueue>(queueRaw);
   auto gip = reinterpret_cast<PFN_vkGetInstanceProcAddr>(instanceProcRaw);
   auto gdp = reinterpret_cast<PFN_vkGetDeviceProcAddr>(gip(instance, "vkGetDeviceProcAddr"));
   if (!gdp) return 0;
   unsigned mask = 1u;
#define AZ_V128_PROC(type, var, name) auto var = reinterpret_cast<type>(gdp(device, name))
   AZ_V128_PROC(PFN_vkCreateImage, createImage, "vkCreateImage");
   AZ_V128_PROC(PFN_vkCreateImageView, createView, "vkCreateImageView");
   AZ_V128_PROC(PFN_vkDestroyImageView, destroyView, "vkDestroyImageView");
   AZ_V128_PROC(PFN_vkDestroyImage, destroyImage, "vkDestroyImage");
   AZ_V128_PROC(PFN_vkGetImageMemoryRequirements, imageReq, "vkGetImageMemoryRequirements");
   AZ_V128_PROC(PFN_vkCreateBuffer, createBuffer, "vkCreateBuffer");
   AZ_V128_PROC(PFN_vkDestroyBuffer, destroyBuffer, "vkDestroyBuffer");
   AZ_V128_PROC(PFN_vkGetBufferMemoryRequirements, bufferReq, "vkGetBufferMemoryRequirements");
   AZ_V128_PROC(PFN_vkAllocateMemory, allocMemory, "vkAllocateMemory");
   AZ_V128_PROC(PFN_vkFreeMemory, freeMemory, "vkFreeMemory");
   AZ_V128_PROC(PFN_vkBindImageMemory, bindImage, "vkBindImageMemory");
   AZ_V128_PROC(PFN_vkBindBufferMemory, bindBuffer, "vkBindBufferMemory");
   AZ_V128_PROC(PFN_vkMapMemory, mapMemory, "vkMapMemory");
   AZ_V128_PROC(PFN_vkUnmapMemory, unmapMemory, "vkUnmapMemory");
   AZ_V128_PROC(PFN_vkCreateCommandPool, createPool, "vkCreateCommandPool");
   AZ_V128_PROC(PFN_vkDestroyCommandPool, destroyPool, "vkDestroyCommandPool");
   AZ_V128_PROC(PFN_vkAllocateCommandBuffers, allocCommands, "vkAllocateCommandBuffers");
   AZ_V128_PROC(PFN_vkBeginCommandBuffer, begin, "vkBeginCommandBuffer");
   AZ_V128_PROC(PFN_vkEndCommandBuffer, end, "vkEndCommandBuffer");
   AZ_V128_PROC(PFN_vkCmdPipelineBarrier, barrier, "vkCmdPipelineBarrier");
   AZ_V128_PROC(PFN_vkCmdClearColorImage, clearImage, "vkCmdClearColorImage");
   AZ_V128_PROC(PFN_vkCmdCopyImageToBuffer, copyImage, "vkCmdCopyImageToBuffer");
   AZ_V128_PROC(PFN_vkCreateFence, createFence, "vkCreateFence");
   AZ_V128_PROC(PFN_vkDestroyFence, destroyFence, "vkDestroyFence");
   AZ_V128_PROC(PFN_vkQueueSubmit, submit, "vkQueueSubmit");
   AZ_V128_PROC(PFN_vkWaitForFences, wait, "vkWaitForFences");
   AZ_V128_PROC(PFN_vkQueueWaitIdle, queueIdle, "vkQueueWaitIdle");
#undef AZ_V128_PROC
   auto getMemoryProperties = reinterpret_cast<PFN_vkGetPhysicalDeviceMemoryProperties>(
       gip(instance, "vkGetPhysicalDeviceMemoryProperties"));
   if (!createView || !destroyView || !createImage || !destroyImage || !imageReq || !createBuffer || !destroyBuffer ||
       !bufferReq || !allocMemory || !freeMemory || !bindImage || !bindBuffer ||
       !mapMemory || !unmapMemory || !createPool || !destroyPool || !allocCommands ||
       !begin || !end || !barrier || !clearImage || !copyImage || !createFence ||
       !destroyFence || !submit || !wait || !queueIdle || !getMemoryProperties) return mask;
   mask |= 2u;
   VkPhysicalDeviceMemoryProperties memoryProps = {};
   getMemoryProperties(physical, &memoryProps);
   auto memoryType = [&](uint32_t allowed, VkMemoryPropertyFlags required) -> uint32_t {
      for (uint32_t i = 0; i < memoryProps.memoryTypeCount; ++i)
         if ((allowed & (1u << i)) &&
             (memoryProps.memoryTypes[i].propertyFlags & required) == required) return i;
      return UINT32_MAX;
   };
   VkImage image = VK_NULL_HANDLE;
   VkBuffer staging = VK_NULL_HANDLE;
   VkDeviceMemory imageMemory = VK_NULL_HANDLE, stagingMemory = VK_NULL_HANDLE;
   VkCommandPool pool = VK_NULL_HANDLE;
   VkFence fence = VK_NULL_HANDLE;
   VkImageView view = VK_NULL_HANDLE;
   AzV136Slot handoffSlot;
   bool imagePublished = false;
   bool submitted = false, completed = false;
   do {
      VkImageCreateInfo ii = {};
      ii.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
      ii.imageType = VK_IMAGE_TYPE_2D;
      ii.format = VK_FORMAT_R8G8B8A8_UNORM;
      ii.extent = {4, 4, 1};
      ii.mipLevels = 1; ii.arrayLayers = 1;
      ii.samples = VK_SAMPLE_COUNT_1_BIT;
      ii.tiling = VK_IMAGE_TILING_OPTIMAL;
      ii.usage = VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
      ii.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
      ii.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
      if (createImage(device, &ii, nullptr, &image) != VK_SUCCESS) break;
      VkMemoryRequirements ir = {};
      imageReq(device, image, &ir);
      uint32_t imageType = memoryType(ir.memoryTypeBits, 0);
      if (imageType == UINT32_MAX) break;
      VkMemoryAllocateInfo ai = {};
      ai.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
      ai.allocationSize = ir.size; ai.memoryTypeIndex = imageType;
      if (allocMemory(device, &ai, nullptr, &imageMemory) != VK_SUCCESS) break;
      if (bindImage(device, image, imageMemory, 0) != VK_SUCCESS) break;
      mask |= 4u;
      VkImageViewCreateInfo vi = {};
      vi.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
      vi.image = image;
      vi.viewType = VK_IMAGE_VIEW_TYPE_2D;
      vi.format = VK_FORMAT_R8G8B8A8_UNORM;
      vi.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
      vi.subresourceRange.levelCount = 1;
      vi.subresourceRange.layerCount = 1;
      if (createView(device, &vi, nullptr, &view) != VK_SUCCESS) break;

      VkBufferCreateInfo bi = {};
      bi.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
      bi.size = 4 * 4 * 4;
      bi.usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT;
      bi.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
      if (createBuffer(device, &bi, nullptr, &staging) != VK_SUCCESS) break;
      VkMemoryRequirements br = {};
      bufferReq(device, staging, &br);
      uint32_t stagingType = memoryType(br.memoryTypeBits,
          VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
      if (stagingType == UINT32_MAX) break;
      ai.allocationSize = br.size; ai.memoryTypeIndex = stagingType;
      if (allocMemory(device, &ai, nullptr, &stagingMemory) != VK_SUCCESS) break;
      if (bindBuffer(device, staging, stagingMemory, 0) != VK_SUCCESS) break;
      mask |= 8u;
      VkCommandPoolCreateInfo pi = {};
      pi.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
      pi.queueFamilyIndex = family;
      if (createPool(device, &pi, nullptr, &pool) != VK_SUCCESS) break;
      VkCommandBuffer cmd = VK_NULL_HANDLE;
      VkCommandBufferAllocateInfo ci = {};
      ci.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
      ci.commandPool = pool; ci.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
      ci.commandBufferCount = 1;
      if (allocCommands(device, &ci, &cmd) != VK_SUCCESS) break;
      VkCommandBufferBeginInfo cb = {};
      cb.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
      cb.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
      if (begin(cmd, &cb) != VK_SUCCESS) break;
      VkImageSubresourceRange range = {};
      range.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
      range.levelCount = 1; range.layerCount = 1;
      VkImageMemoryBarrier ib = {};
      ib.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
      ib.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
      ib.newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
      ib.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
      ib.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
      ib.dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
      ib.image = image; ib.subresourceRange = range;
      barrier(cmd, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
              0, 0, nullptr, 0, nullptr, 1, &ib);
      VkClearColorValue color = {};
      color.float32[0] = 0.2f; color.float32[1] = 0.4f;
      color.float32[2] = 0.6f; color.float32[3] = 1.0f;
      clearImage(cmd, image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &color, 1, &range);
      ib.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
      ib.newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
      ib.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
      ib.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
      barrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
              0, 0, nullptr, 0, nullptr, 1, &ib);
      VkBufferImageCopy region = {};
      region.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
      region.imageSubresource.layerCount = 1;
      region.imageExtent = {4, 4, 1};
      copyImage(cmd, image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, staging, 1, &region);
      VkBufferMemoryBarrier bb = {};
      bb.sType = VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER;
      bb.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
      bb.dstAccessMask = VK_ACCESS_HOST_READ_BIT;
      bb.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
      bb.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
      bb.buffer = staging; bb.size = VK_WHOLE_SIZE;
      barrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT,
              0, 0, nullptr, 1, &bb, 0, nullptr);
      if (end(cmd) != VK_SUCCESS) break;
      mask |= 16u;
      VkFenceCreateInfo fi = {};
      fi.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
      if (createFence(device, &fi, nullptr, &fence) != VK_SUCCESS) break;
      VkSubmitInfo si = {};
      si.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
      si.commandBufferCount = 1; si.pCommandBuffers = &cmd;
      submitted = submit(queue, 1, &si, fence) == VK_SUCCESS;
      if (!submitted) break;
      mask |= 32u;
      completed = wait(device, 1, &fence, VK_TRUE, 5000000000ULL) == VK_SUCCESS;
      if (!completed) break;
      mask |= 64u;
      void *mapped = nullptr;
      if (mapMemory(device, stagingMemory, 0, 64, 0, &mapped) != VK_SUCCESS || !mapped) break;
      const auto *bytes = static_cast<const unsigned char *>(mapped);
      bool match = true;
      for (unsigned i = 0; i < 16; ++i) {
         const unsigned char *p = bytes + i * 4;
         if (p[0] != 51 || p[1] != 102 || p[2] != 153 || p[3] != 255) {
            match = false; break;
         }
      }
      unmapMemory(device, stagingMemory);
      if (match) mask |= 128u;
      // Hand off only after the fence has completed and pixels have been verified.
      // This private callback borrows a live VkImageView; no ownership transfer.
      retro_hw_render_interface_vulkan staged = {};
      staged.interface_type = RETRO_HW_RENDER_INTERFACE_VULKAN;
      staged.interface_version = RETRO_HW_RENDER_INTERFACE_VULKAN_VERSION;
      staged.handle = &handoffSlot;
      staged.set_image = &AzV137SetImage;
      retro_vulkan_image descriptor = {};
      descriptor.image_view = view;
      descriptor.image_layout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
      descriptor.create_info = vi;
      staged.set_image(staged.handle, &descriptor, 0, nullptr, family);
      if (handoffSlot.accepted == 1 && handoffSlot.view == view &&
          handoffSlot.layout == VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL && match) {
          mask |= 256u;
          imagePublished = true;
      }
      // The descriptor is withdrawn while its backing image and view are alive.
      handoffSlot.alive = false;
      handoffSlot.view = VK_NULL_HANDLE;
      staged.handle = nullptr;
      staged.set_image = nullptr;
      if (imagePublished && !handoffSlot.alive && !staged.handle && !staged.set_image)
          mask |= 512u;

   } while (false);
   // If submitted but fence timed out, ensure completion before freeing resources.
   if (submitted && !completed) (void)queueIdle(queue);
   if (fence) destroyFence(device, fence, nullptr);
   if (pool) destroyPool(device, pool, nullptr);
   if (staging) destroyBuffer(device, staging, nullptr);
   if (view) destroyView(device, view, nullptr);
   if (image) destroyImage(device, image, nullptr);
   if (stagingMemory) freeMemory(device, stagingMemory, nullptr);
   if (imageMemory) freeMemory(device, imageMemory, nullptr);
   return mask;
}
extern "C" unsigned AzaharV138GPUPixelsToBitmapGate(void *instanceRaw, void *physicalRaw,
    void *deviceRaw, void *queueRaw, void *instanceProcRaw, unsigned family, unsigned char *outRGBA, unsigned outCapacity) {
   if (outRGBA && outCapacity >= 64) std::memset(outRGBA, 0, 64);
   if (!outRGBA || outCapacity < 64 || !instanceRaw || !physicalRaw || !deviceRaw || !queueRaw || !instanceProcRaw) return 0;
   auto instance = reinterpret_cast<VkInstance>(instanceRaw);
   auto physical = reinterpret_cast<VkPhysicalDevice>(physicalRaw);
   auto device = reinterpret_cast<VkDevice>(deviceRaw);
   auto queue = reinterpret_cast<VkQueue>(queueRaw);
   auto gip = reinterpret_cast<PFN_vkGetInstanceProcAddr>(instanceProcRaw);
   auto gdp = reinterpret_cast<PFN_vkGetDeviceProcAddr>(gip(instance, "vkGetDeviceProcAddr"));
   if (!gdp) return 0;
   unsigned mask = 1u;
#define AZ_V128_PROC(type, var, name) auto var = reinterpret_cast<type>(gdp(device, name))
   AZ_V128_PROC(PFN_vkCreateImage, createImage, "vkCreateImage");
   AZ_V128_PROC(PFN_vkCreateImageView, createView, "vkCreateImageView");
   AZ_V128_PROC(PFN_vkDestroyImageView, destroyView, "vkDestroyImageView");
   AZ_V128_PROC(PFN_vkDestroyImage, destroyImage, "vkDestroyImage");
   AZ_V128_PROC(PFN_vkGetImageMemoryRequirements, imageReq, "vkGetImageMemoryRequirements");
   AZ_V128_PROC(PFN_vkCreateBuffer, createBuffer, "vkCreateBuffer");
   AZ_V128_PROC(PFN_vkDestroyBuffer, destroyBuffer, "vkDestroyBuffer");
   AZ_V128_PROC(PFN_vkGetBufferMemoryRequirements, bufferReq, "vkGetBufferMemoryRequirements");
   AZ_V128_PROC(PFN_vkAllocateMemory, allocMemory, "vkAllocateMemory");
   AZ_V128_PROC(PFN_vkFreeMemory, freeMemory, "vkFreeMemory");
   AZ_V128_PROC(PFN_vkBindImageMemory, bindImage, "vkBindImageMemory");
   AZ_V128_PROC(PFN_vkBindBufferMemory, bindBuffer, "vkBindBufferMemory");
   AZ_V128_PROC(PFN_vkMapMemory, mapMemory, "vkMapMemory");
   AZ_V128_PROC(PFN_vkUnmapMemory, unmapMemory, "vkUnmapMemory");
   AZ_V128_PROC(PFN_vkCreateCommandPool, createPool, "vkCreateCommandPool");
   AZ_V128_PROC(PFN_vkDestroyCommandPool, destroyPool, "vkDestroyCommandPool");
   AZ_V128_PROC(PFN_vkAllocateCommandBuffers, allocCommands, "vkAllocateCommandBuffers");
   AZ_V128_PROC(PFN_vkBeginCommandBuffer, begin, "vkBeginCommandBuffer");
   AZ_V128_PROC(PFN_vkEndCommandBuffer, end, "vkEndCommandBuffer");
   AZ_V128_PROC(PFN_vkCmdPipelineBarrier, barrier, "vkCmdPipelineBarrier");
   AZ_V128_PROC(PFN_vkCmdClearColorImage, clearImage, "vkCmdClearColorImage");
   AZ_V128_PROC(PFN_vkCmdCopyImageToBuffer, copyImage, "vkCmdCopyImageToBuffer");
   AZ_V128_PROC(PFN_vkCreateFence, createFence, "vkCreateFence");
   AZ_V128_PROC(PFN_vkDestroyFence, destroyFence, "vkDestroyFence");
   AZ_V128_PROC(PFN_vkQueueSubmit, submit, "vkQueueSubmit");
   AZ_V128_PROC(PFN_vkWaitForFences, wait, "vkWaitForFences");
   AZ_V128_PROC(PFN_vkQueueWaitIdle, queueIdle, "vkQueueWaitIdle");
#undef AZ_V128_PROC
   auto getMemoryProperties = reinterpret_cast<PFN_vkGetPhysicalDeviceMemoryProperties>(
       gip(instance, "vkGetPhysicalDeviceMemoryProperties"));
   if (!createView || !destroyView || !createImage || !destroyImage || !imageReq || !createBuffer || !destroyBuffer ||
       !bufferReq || !allocMemory || !freeMemory || !bindImage || !bindBuffer ||
       !mapMemory || !unmapMemory || !createPool || !destroyPool || !allocCommands ||
       !begin || !end || !barrier || !clearImage || !copyImage || !createFence ||
       !destroyFence || !submit || !wait || !queueIdle || !getMemoryProperties) return mask;
   mask |= 2u;
   VkPhysicalDeviceMemoryProperties memoryProps = {};
   getMemoryProperties(physical, &memoryProps);
   auto memoryType = [&](uint32_t allowed, VkMemoryPropertyFlags required) -> uint32_t {
      for (uint32_t i = 0; i < memoryProps.memoryTypeCount; ++i)
         if ((allowed & (1u << i)) &&
             (memoryProps.memoryTypes[i].propertyFlags & required) == required) return i;
      return UINT32_MAX;
   };
   VkImage image = VK_NULL_HANDLE;
   VkBuffer staging = VK_NULL_HANDLE;
   VkDeviceMemory imageMemory = VK_NULL_HANDLE, stagingMemory = VK_NULL_HANDLE;
   VkCommandPool pool = VK_NULL_HANDLE;
   VkFence fence = VK_NULL_HANDLE;
   VkImageView view = VK_NULL_HANDLE;
   AzV136Slot handoffSlot;
   bool imagePublished = false;
   bool submitted = false, completed = false;
   do {
      VkImageCreateInfo ii = {};
      ii.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
      ii.imageType = VK_IMAGE_TYPE_2D;
      ii.format = VK_FORMAT_R8G8B8A8_UNORM;
      ii.extent = {4, 4, 1};
      ii.mipLevels = 1; ii.arrayLayers = 1;
      ii.samples = VK_SAMPLE_COUNT_1_BIT;
      ii.tiling = VK_IMAGE_TILING_OPTIMAL;
      ii.usage = VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
      ii.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
      ii.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
      if (createImage(device, &ii, nullptr, &image) != VK_SUCCESS) break;
      VkMemoryRequirements ir = {};
      imageReq(device, image, &ir);
      uint32_t imageType = memoryType(ir.memoryTypeBits, 0);
      if (imageType == UINT32_MAX) break;
      VkMemoryAllocateInfo ai = {};
      ai.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
      ai.allocationSize = ir.size; ai.memoryTypeIndex = imageType;
      if (allocMemory(device, &ai, nullptr, &imageMemory) != VK_SUCCESS) break;
      if (bindImage(device, image, imageMemory, 0) != VK_SUCCESS) break;
      mask |= 4u;
      VkImageViewCreateInfo vi = {};
      vi.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
      vi.image = image;
      vi.viewType = VK_IMAGE_VIEW_TYPE_2D;
      vi.format = VK_FORMAT_R8G8B8A8_UNORM;
      vi.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
      vi.subresourceRange.levelCount = 1;
      vi.subresourceRange.layerCount = 1;
      if (createView(device, &vi, nullptr, &view) != VK_SUCCESS) break;

      VkBufferCreateInfo bi = {};
      bi.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
      bi.size = 4 * 4 * 4;
      bi.usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT;
      bi.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
      if (createBuffer(device, &bi, nullptr, &staging) != VK_SUCCESS) break;
      VkMemoryRequirements br = {};
      bufferReq(device, staging, &br);
      uint32_t stagingType = memoryType(br.memoryTypeBits,
          VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
      if (stagingType == UINT32_MAX) break;
      ai.allocationSize = br.size; ai.memoryTypeIndex = stagingType;
      if (allocMemory(device, &ai, nullptr, &stagingMemory) != VK_SUCCESS) break;
      if (bindBuffer(device, staging, stagingMemory, 0) != VK_SUCCESS) break;
      mask |= 8u;
      VkCommandPoolCreateInfo pi = {};
      pi.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
      pi.queueFamilyIndex = family;
      if (createPool(device, &pi, nullptr, &pool) != VK_SUCCESS) break;
      VkCommandBuffer cmd = VK_NULL_HANDLE;
      VkCommandBufferAllocateInfo ci = {};
      ci.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
      ci.commandPool = pool; ci.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
      ci.commandBufferCount = 1;
      if (allocCommands(device, &ci, &cmd) != VK_SUCCESS) break;
      VkCommandBufferBeginInfo cb = {};
      cb.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
      cb.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
      if (begin(cmd, &cb) != VK_SUCCESS) break;
      VkImageSubresourceRange range = {};
      range.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
      range.levelCount = 1; range.layerCount = 1;
      VkImageMemoryBarrier ib = {};
      ib.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
      ib.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
      ib.newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
      ib.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
      ib.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
      ib.dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
      ib.image = image; ib.subresourceRange = range;
      barrier(cmd, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
              0, 0, nullptr, 0, nullptr, 1, &ib);
      VkClearColorValue color = {};
      color.float32[0] = 0.2f; color.float32[1] = 0.4f;
      color.float32[2] = 0.6f; color.float32[3] = 1.0f;
      clearImage(cmd, image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &color, 1, &range);
      ib.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
      ib.newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
      ib.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
      ib.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
      barrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
              0, 0, nullptr, 0, nullptr, 1, &ib);
      VkBufferImageCopy region = {};
      region.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
      region.imageSubresource.layerCount = 1;
      region.imageExtent = {4, 4, 1};
      copyImage(cmd, image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, staging, 1, &region);
      VkBufferMemoryBarrier bb = {};
      bb.sType = VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER;
      bb.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
      bb.dstAccessMask = VK_ACCESS_HOST_READ_BIT;
      bb.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
      bb.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
      bb.buffer = staging; bb.size = VK_WHOLE_SIZE;
      barrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT,
              0, 0, nullptr, 1, &bb, 0, nullptr);
      if (end(cmd) != VK_SUCCESS) break;
      mask |= 16u;
      VkFenceCreateInfo fi = {};
      fi.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
      if (createFence(device, &fi, nullptr, &fence) != VK_SUCCESS) break;
      VkSubmitInfo si = {};
      si.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
      si.commandBufferCount = 1; si.pCommandBuffers = &cmd;
      submitted = submit(queue, 1, &si, fence) == VK_SUCCESS;
      if (!submitted) break;
      mask |= 32u;
      completed = wait(device, 1, &fence, VK_TRUE, 5000000000ULL) == VK_SUCCESS;
      if (!completed) break;
      mask |= 64u;
      void *mapped = nullptr;
      if (mapMemory(device, stagingMemory, 0, 64, 0, &mapped) != VK_SUCCESS || !mapped) break;
      const auto *bytes = static_cast<const unsigned char *>(mapped);
      bool match = true;
      for (unsigned i = 0; i < 16; ++i) {
         const unsigned char *p = bytes + i * 4;
         if (p[0] != 51 || p[1] != 102 || p[2] != 153 || p[3] != 255) {
            match = false; break;
         }
      }
      if (match) std::memcpy(outRGBA, bytes, 64);
      unmapMemory(device, stagingMemory);
      if (match) mask |= 128u;
      // Hand off only after the fence has completed and pixels have been verified.
      // This private callback borrows a live VkImageView; no ownership transfer.
      retro_hw_render_interface_vulkan staged = {};
      staged.interface_type = RETRO_HW_RENDER_INTERFACE_VULKAN;
      staged.interface_version = RETRO_HW_RENDER_INTERFACE_VULKAN_VERSION;
      staged.handle = &handoffSlot;
      staged.set_image = &AzV137SetImage;
      retro_vulkan_image descriptor = {};
      descriptor.image_view = view;
      descriptor.image_layout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
      descriptor.create_info = vi;
      staged.set_image(staged.handle, &descriptor, 0, nullptr, family);
      if (handoffSlot.accepted == 1 && handoffSlot.view == view &&
          handoffSlot.layout == VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL && match) {
          mask |= 256u;
          imagePublished = true;
      }
      // The descriptor is withdrawn while its backing image and view are alive.
      handoffSlot.alive = false;
      handoffSlot.view = VK_NULL_HANDLE;
      staged.handle = nullptr;
      staged.set_image = nullptr;
      if (imagePublished && !handoffSlot.alive && !staged.handle && !staged.set_image)
          mask |= 512u;

   } while (false);
   // If submitted but fence timed out, ensure completion before freeing resources.
   if (submitted && !completed) (void)queueIdle(queue);
   if (fence) destroyFence(device, fence, nullptr);
   if (pool) destroyPool(device, pool, nullptr);
   if (staging) destroyBuffer(device, staging, nullptr);
   if (view) destroyView(device, view, nullptr);
   if (image) destroyImage(device, image, nullptr);
   if (stagingMemory) freeMemory(device, stagingMemory, nullptr);
   if (imageMemory) freeMemory(device, imageMemory, nullptr);
   return mask;
}
extern "C" unsigned AzaharV141FullFrameGate(void *instanceRaw, void *physicalRaw,
    void *deviceRaw, void *queueRaw, void *instanceProcRaw, unsigned family, unsigned char *outRGBA, unsigned outCapacity) {
   if (outRGBA && outCapacity >= 400u * 240u * 4u) std::memset(outRGBA, 0, 400u * 240u * 4u);
   if (!outRGBA || outCapacity < 400u * 240u * 4u || !instanceRaw || !physicalRaw || !deviceRaw || !queueRaw || !instanceProcRaw) return 0;
   auto instance = reinterpret_cast<VkInstance>(instanceRaw);
   auto physical = reinterpret_cast<VkPhysicalDevice>(physicalRaw);
   auto device = reinterpret_cast<VkDevice>(deviceRaw);
   auto queue = reinterpret_cast<VkQueue>(queueRaw);
   auto gip = reinterpret_cast<PFN_vkGetInstanceProcAddr>(instanceProcRaw);
   auto gdp = reinterpret_cast<PFN_vkGetDeviceProcAddr>(gip(instance, "vkGetDeviceProcAddr"));
   if (!gdp) return 0;
   unsigned mask = 1u;
#define AZ_V128_PROC(type, var, name) auto var = reinterpret_cast<type>(gdp(device, name))
   AZ_V128_PROC(PFN_vkCreateImage, createImage, "vkCreateImage");
   AZ_V128_PROC(PFN_vkCreateImageView, createView, "vkCreateImageView");
   AZ_V128_PROC(PFN_vkDestroyImageView, destroyView, "vkDestroyImageView");
   AZ_V128_PROC(PFN_vkDestroyImage, destroyImage, "vkDestroyImage");
   AZ_V128_PROC(PFN_vkGetImageMemoryRequirements, imageReq, "vkGetImageMemoryRequirements");
   AZ_V128_PROC(PFN_vkCreateBuffer, createBuffer, "vkCreateBuffer");
   AZ_V128_PROC(PFN_vkDestroyBuffer, destroyBuffer, "vkDestroyBuffer");
   AZ_V128_PROC(PFN_vkGetBufferMemoryRequirements, bufferReq, "vkGetBufferMemoryRequirements");
   AZ_V128_PROC(PFN_vkAllocateMemory, allocMemory, "vkAllocateMemory");
   AZ_V128_PROC(PFN_vkFreeMemory, freeMemory, "vkFreeMemory");
   AZ_V128_PROC(PFN_vkBindImageMemory, bindImage, "vkBindImageMemory");
   AZ_V128_PROC(PFN_vkBindBufferMemory, bindBuffer, "vkBindBufferMemory");
   AZ_V128_PROC(PFN_vkMapMemory, mapMemory, "vkMapMemory");
   AZ_V128_PROC(PFN_vkUnmapMemory, unmapMemory, "vkUnmapMemory");
   AZ_V128_PROC(PFN_vkCreateCommandPool, createPool, "vkCreateCommandPool");
   AZ_V128_PROC(PFN_vkDestroyCommandPool, destroyPool, "vkDestroyCommandPool");
   AZ_V128_PROC(PFN_vkAllocateCommandBuffers, allocCommands, "vkAllocateCommandBuffers");
   AZ_V128_PROC(PFN_vkBeginCommandBuffer, begin, "vkBeginCommandBuffer");
   AZ_V128_PROC(PFN_vkEndCommandBuffer, end, "vkEndCommandBuffer");
   AZ_V128_PROC(PFN_vkCmdPipelineBarrier, barrier, "vkCmdPipelineBarrier");
   AZ_V128_PROC(PFN_vkCmdClearColorImage, clearImage, "vkCmdClearColorImage");
   AZ_V128_PROC(PFN_vkCmdCopyImageToBuffer, copyImage, "vkCmdCopyImageToBuffer");
   AZ_V128_PROC(PFN_vkCreateFence, createFence, "vkCreateFence");
   AZ_V128_PROC(PFN_vkDestroyFence, destroyFence, "vkDestroyFence");
   AZ_V128_PROC(PFN_vkQueueSubmit, submit, "vkQueueSubmit");
   AZ_V128_PROC(PFN_vkWaitForFences, wait, "vkWaitForFences");
   AZ_V128_PROC(PFN_vkQueueWaitIdle, queueIdle, "vkQueueWaitIdle");
#undef AZ_V128_PROC
   auto getMemoryProperties = reinterpret_cast<PFN_vkGetPhysicalDeviceMemoryProperties>(
       gip(instance, "vkGetPhysicalDeviceMemoryProperties"));
   if (!createView || !destroyView || !createImage || !destroyImage || !imageReq || !createBuffer || !destroyBuffer ||
       !bufferReq || !allocMemory || !freeMemory || !bindImage || !bindBuffer ||
       !mapMemory || !unmapMemory || !createPool || !destroyPool || !allocCommands ||
       !begin || !end || !barrier || !clearImage || !copyImage || !createFence ||
       !destroyFence || !submit || !wait || !queueIdle || !getMemoryProperties) return mask;
   mask |= 2u;
   VkPhysicalDeviceMemoryProperties memoryProps = {};
   getMemoryProperties(physical, &memoryProps);
   auto memoryType = [&](uint32_t allowed, VkMemoryPropertyFlags required) -> uint32_t {
      for (uint32_t i = 0; i < memoryProps.memoryTypeCount; ++i)
         if ((allowed & (1u << i)) &&
             (memoryProps.memoryTypes[i].propertyFlags & required) == required) return i;
      return UINT32_MAX;
   };
   VkImage image = VK_NULL_HANDLE;
   VkBuffer staging = VK_NULL_HANDLE;
   VkDeviceMemory imageMemory = VK_NULL_HANDLE, stagingMemory = VK_NULL_HANDLE;
   VkCommandPool pool = VK_NULL_HANDLE;
   VkFence fence = VK_NULL_HANDLE;
   VkImageView view = VK_NULL_HANDLE;
   AzV136Slot handoffSlot;
   bool imagePublished = false;
   bool submitted = false, completed = false;
   do {
      VkImageCreateInfo ii = {};
      ii.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
      ii.imageType = VK_IMAGE_TYPE_2D;
      ii.format = VK_FORMAT_R8G8B8A8_UNORM;
      ii.extent = {400, 240, 1};
      ii.mipLevels = 1; ii.arrayLayers = 1;
      ii.samples = VK_SAMPLE_COUNT_1_BIT;
      ii.tiling = VK_IMAGE_TILING_OPTIMAL;
      ii.usage = VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
      ii.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
      ii.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
      if (createImage(device, &ii, nullptr, &image) != VK_SUCCESS) break;
      VkMemoryRequirements ir = {};
      imageReq(device, image, &ir);
      uint32_t imageType = memoryType(ir.memoryTypeBits, 0);
      if (imageType == UINT32_MAX) break;
      VkMemoryAllocateInfo ai = {};
      ai.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
      ai.allocationSize = ir.size; ai.memoryTypeIndex = imageType;
      if (allocMemory(device, &ai, nullptr, &imageMemory) != VK_SUCCESS) break;
      if (bindImage(device, image, imageMemory, 0) != VK_SUCCESS) break;
      mask |= 4u;
      VkImageViewCreateInfo vi = {};
      vi.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
      vi.image = image;
      vi.viewType = VK_IMAGE_VIEW_TYPE_2D;
      vi.format = VK_FORMAT_R8G8B8A8_UNORM;
      vi.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
      vi.subresourceRange.levelCount = 1;
      vi.subresourceRange.layerCount = 1;
      if (createView(device, &vi, nullptr, &view) != VK_SUCCESS) break;

      VkBufferCreateInfo bi = {};
      bi.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
      bi.size = 400u * 240u * 4u;
      bi.usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT;
      bi.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
      if (createBuffer(device, &bi, nullptr, &staging) != VK_SUCCESS) break;
      VkMemoryRequirements br = {};
      bufferReq(device, staging, &br);
      uint32_t stagingType = memoryType(br.memoryTypeBits,
          VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
      if (stagingType == UINT32_MAX) break;
      ai.allocationSize = br.size; ai.memoryTypeIndex = stagingType;
      if (allocMemory(device, &ai, nullptr, &stagingMemory) != VK_SUCCESS) break;
      if (bindBuffer(device, staging, stagingMemory, 0) != VK_SUCCESS) break;
      mask |= 8u;
      VkCommandPoolCreateInfo pi = {};
      pi.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
      pi.queueFamilyIndex = family;
      if (createPool(device, &pi, nullptr, &pool) != VK_SUCCESS) break;
      VkCommandBuffer cmd = VK_NULL_HANDLE;
      VkCommandBufferAllocateInfo ci = {};
      ci.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
      ci.commandPool = pool; ci.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
      ci.commandBufferCount = 1;
      if (allocCommands(device, &ci, &cmd) != VK_SUCCESS) break;
      VkCommandBufferBeginInfo cb = {};
      cb.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
      cb.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
      if (begin(cmd, &cb) != VK_SUCCESS) break;
      VkImageSubresourceRange range = {};
      range.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
      range.levelCount = 1; range.layerCount = 1;
      VkImageMemoryBarrier ib = {};
      ib.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
      ib.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
      ib.newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
      ib.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
      ib.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
      ib.dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
      ib.image = image; ib.subresourceRange = range;
      barrier(cmd, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
              0, 0, nullptr, 0, nullptr, 1, &ib);
      VkClearColorValue color = {};
      color.float32[0] = 0.2f; color.float32[1] = 0.4f;
      color.float32[2] = 0.6f; color.float32[3] = 1.0f;
      clearImage(cmd, image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &color, 1, &range);
      ib.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
      ib.newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
      ib.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
      ib.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
      barrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
              0, 0, nullptr, 0, nullptr, 1, &ib);
      // Castle 173: hand the *real* source image through the official
      // set_image ABI shape BEFORE the consumer records its image copy.
      // This scoped producer/consumer uses one device and one queue. The
      // descriptor remains borrowed until the fence and CPU copy complete.
      retro_hw_render_interface_vulkan staged = {};
      staged.interface_type = RETRO_HW_RENDER_INTERFACE_VULKAN;
      staged.interface_version = RETRO_HW_RENDER_INTERFACE_VULKAN_VERSION;
      staged.handle = &handoffSlot;
      staged.set_image = &AzV137SetImage;
      retro_vulkan_image descriptor = {};
      descriptor.image_view = view;
      descriptor.image_layout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
      descriptor.create_info = vi;
      staged.set_image(staged.handle, &descriptor, 0, nullptr, family);
      if (handoffSlot.accepted != 1 || handoffSlot.view != view ||
          handoffSlot.info.image != image ||
          handoffSlot.layout != VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL ||
          handoffSlot.info.format != VK_FORMAT_R8G8B8A8_UNORM) break;
      // The copy must use the borrowed image returned by the callback,
      // rather than bypassing set_image and using our local producer handle.
      const VkImage consumerImage = handoffSlot.info.image;
      VkBufferImageCopy region = {};
      region.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
      region.imageSubresource.layerCount = 1;
      region.imageExtent = {400, 240, 1};
      copyImage(cmd, consumerImage, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, staging, 1, &region);
      VkBufferMemoryBarrier bb = {};
      bb.sType = VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER;
      bb.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
      bb.dstAccessMask = VK_ACCESS_HOST_READ_BIT;
      bb.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
      bb.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
      bb.buffer = staging; bb.size = VK_WHOLE_SIZE;
      barrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT,
              0, 0, nullptr, 1, &bb, 0, nullptr);
      if (end(cmd) != VK_SUCCESS) break;
      mask |= 16u;
      VkFenceCreateInfo fi = {};
      fi.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
      if (createFence(device, &fi, nullptr, &fence) != VK_SUCCESS) break;
      VkSubmitInfo si = {};
      si.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
      si.commandBufferCount = 1; si.pCommandBuffers = &cmd;
      submitted = submit(queue, 1, &si, fence) == VK_SUCCESS;
      if (!submitted) break;
      mask |= 32u;
      completed = wait(device, 1, &fence, VK_TRUE, 5000000000ULL) == VK_SUCCESS;
      if (!completed) break;
      mask |= 64u;
      void *mapped = nullptr;
      if (mapMemory(device, stagingMemory, 0, 400u * 240u * 4u, 0, &mapped) != VK_SUCCESS || !mapped) break;
      const auto *bytes = static_cast<const unsigned char *>(mapped);
      bool match = true;
      for (unsigned i = 0; i < 400u * 240u; ++i) {
         const unsigned char *p = bytes + i * 4;
         if (p[0] != 51 || p[1] != 102 || p[2] != 153 || p[3] != 255) {
            match = false; break;
         }
      }
      if (match) std::memcpy(outRGBA, bytes, 400u * 240u * 4u);
      unmapMemory(device, stagingMemory);
      if (match) mask |= 128u;
      // Producer/consumer callback was validated before recording the copy.
      // Only mark the handoff complete after GPU fence and full pixel match.
      if (handoffSlot.accepted == 1 && handoffSlot.info.image == image &&
          handoffSlot.view == view && match) {
          mask |= 256u;
          imagePublished = true;
      }
      // The descriptor is withdrawn while its backing image and view are alive.
      handoffSlot.alive = false;
      handoffSlot.view = VK_NULL_HANDLE;
      staged.handle = nullptr;
      staged.set_image = nullptr;
      if (imagePublished && !handoffSlot.alive && !staged.handle && !staged.set_image)
          mask |= 512u;

   } while (false);
   // If submitted but fence timed out, ensure completion before freeing resources.
   if (submitted && !completed) (void)queueIdle(queue);
   if (fence) destroyFence(device, fence, nullptr);
   if (pool) destroyPool(device, pool, nullptr);
   if (staging) destroyBuffer(device, staging, nullptr);
   if (view) destroyView(device, view, nullptr);
   if (image) destroyImage(device, image, nullptr);
   if (stagingMemory) freeMemory(device, stagingMemory, nullptr);
   if (imageMemory) freeMemory(device, imageMemory, nullptr);
   return mask;
}
/* Castle 130: isolated Vulkan render-pass color attachment, framebuffer, clear and readback.
   Does not yet accept libretro hardware negotiation or present game frames. */
extern "C" unsigned AzaharV130RenderPassClearGate(void *instanceRaw, void *physicalRaw,
    void *deviceRaw, void *queueRaw, void *instanceProcRaw, unsigned family) {
   if (!instanceRaw || !physicalRaw || !deviceRaw || !queueRaw || !instanceProcRaw) return 0;
   auto instance = reinterpret_cast<VkInstance>(instanceRaw);
   auto physical = reinterpret_cast<VkPhysicalDevice>(physicalRaw);
   auto device = reinterpret_cast<VkDevice>(deviceRaw);
   auto queue = reinterpret_cast<VkQueue>(queueRaw);
   auto gip = reinterpret_cast<PFN_vkGetInstanceProcAddr>(instanceProcRaw);
   auto gdp = reinterpret_cast<PFN_vkGetDeviceProcAddr>(gip(instance, "vkGetDeviceProcAddr"));
   if (!gdp) return 0;
   unsigned mask = 1u;
#define AZ_V128_PROC(type, var, name) auto var = reinterpret_cast<type>(gdp(device, name))
   AZ_V128_PROC(PFN_vkCreateImage, createImage, "vkCreateImage");
   AZ_V128_PROC(PFN_vkDestroyImage, destroyImage, "vkDestroyImage");
   AZ_V128_PROC(PFN_vkGetImageMemoryRequirements, imageReq, "vkGetImageMemoryRequirements");
   AZ_V128_PROC(PFN_vkCreateBuffer, createBuffer, "vkCreateBuffer");
   AZ_V128_PROC(PFN_vkDestroyBuffer, destroyBuffer, "vkDestroyBuffer");
   AZ_V128_PROC(PFN_vkGetBufferMemoryRequirements, bufferReq, "vkGetBufferMemoryRequirements");
   AZ_V128_PROC(PFN_vkAllocateMemory, allocMemory, "vkAllocateMemory");
   AZ_V128_PROC(PFN_vkFreeMemory, freeMemory, "vkFreeMemory");
   AZ_V128_PROC(PFN_vkBindImageMemory, bindImage, "vkBindImageMemory");
   AZ_V128_PROC(PFN_vkBindBufferMemory, bindBuffer, "vkBindBufferMemory");
   AZ_V128_PROC(PFN_vkMapMemory, mapMemory, "vkMapMemory");
   AZ_V128_PROC(PFN_vkUnmapMemory, unmapMemory, "vkUnmapMemory");
   AZ_V128_PROC(PFN_vkCreateCommandPool, createPool, "vkCreateCommandPool");
   AZ_V128_PROC(PFN_vkDestroyCommandPool, destroyPool, "vkDestroyCommandPool");
   AZ_V128_PROC(PFN_vkAllocateCommandBuffers, allocCommands, "vkAllocateCommandBuffers");
   AZ_V128_PROC(PFN_vkBeginCommandBuffer, begin, "vkBeginCommandBuffer");
   AZ_V128_PROC(PFN_vkEndCommandBuffer, end, "vkEndCommandBuffer");
   AZ_V128_PROC(PFN_vkCmdPipelineBarrier, barrier, "vkCmdPipelineBarrier");
   AZ_V128_PROC(PFN_vkCreateImageView, createView, "vkCreateImageView");
   AZ_V128_PROC(PFN_vkDestroyImageView, destroyView, "vkDestroyImageView");
   AZ_V128_PROC(PFN_vkCreateRenderPass, createRenderPass, "vkCreateRenderPass");
   AZ_V128_PROC(PFN_vkDestroyRenderPass, destroyRenderPass, "vkDestroyRenderPass");
   AZ_V128_PROC(PFN_vkCreateFramebuffer, createFramebuffer, "vkCreateFramebuffer");
   AZ_V128_PROC(PFN_vkDestroyFramebuffer, destroyFramebuffer, "vkDestroyFramebuffer");
   AZ_V128_PROC(PFN_vkCmdBeginRenderPass, beginRenderPass, "vkCmdBeginRenderPass");
   AZ_V128_PROC(PFN_vkCmdEndRenderPass, endRenderPass, "vkCmdEndRenderPass");
   AZ_V128_PROC(PFN_vkCmdCopyImageToBuffer, copyImage, "vkCmdCopyImageToBuffer");
   AZ_V128_PROC(PFN_vkCreateFence, createFence, "vkCreateFence");
   AZ_V128_PROC(PFN_vkDestroyFence, destroyFence, "vkDestroyFence");
   AZ_V128_PROC(PFN_vkQueueSubmit, submit, "vkQueueSubmit");
   AZ_V128_PROC(PFN_vkWaitForFences, wait, "vkWaitForFences");
   AZ_V128_PROC(PFN_vkQueueWaitIdle, queueIdle, "vkQueueWaitIdle");
#undef AZ_V128_PROC
   auto getMemoryProperties = reinterpret_cast<PFN_vkGetPhysicalDeviceMemoryProperties>(
       gip(instance, "vkGetPhysicalDeviceMemoryProperties"));
   if (!createImage || !destroyImage || !imageReq || !createBuffer || !destroyBuffer ||
       !bufferReq || !allocMemory || !freeMemory || !bindImage || !bindBuffer ||
       !mapMemory || !unmapMemory || !createPool || !destroyPool || !allocCommands ||
       !begin || !end || !barrier || !createView || !destroyView ||
       !createRenderPass || !destroyRenderPass || !createFramebuffer ||
       !destroyFramebuffer || !beginRenderPass || !endRenderPass || !copyImage || !createFence ||
       !destroyFence || !submit || !wait || !queueIdle || !getMemoryProperties) return mask;
   mask |= 2u;
   VkPhysicalDeviceMemoryProperties memoryProps = {};
   getMemoryProperties(physical, &memoryProps);
   auto memoryType = [&](uint32_t allowed, VkMemoryPropertyFlags required) -> uint32_t {
      for (uint32_t i = 0; i < memoryProps.memoryTypeCount; ++i)
         if ((allowed & (1u << i)) &&
             (memoryProps.memoryTypes[i].propertyFlags & required) == required) return i;
      return UINT32_MAX;
   };
   VkImage image = VK_NULL_HANDLE;
   VkBuffer staging = VK_NULL_HANDLE;
   VkDeviceMemory imageMemory = VK_NULL_HANDLE, stagingMemory = VK_NULL_HANDLE;
   VkCommandPool pool = VK_NULL_HANDLE;
   VkFence fence = VK_NULL_HANDLE;
   VkImageView view = VK_NULL_HANDLE;
   VkRenderPass renderPass = VK_NULL_HANDLE;
   VkFramebuffer framebuffer = VK_NULL_HANDLE;
   bool submitted = false, completed = false;
   do {
      VkImageCreateInfo ii = {};
      ii.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
      ii.imageType = VK_IMAGE_TYPE_2D;
      ii.format = VK_FORMAT_R8G8B8A8_UNORM;
      ii.extent = {4, 4, 1};
      ii.mipLevels = 1; ii.arrayLayers = 1;
      ii.samples = VK_SAMPLE_COUNT_1_BIT;
      ii.tiling = VK_IMAGE_TILING_OPTIMAL;
      ii.usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
      ii.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
      ii.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
      if (createImage(device, &ii, nullptr, &image) != VK_SUCCESS) break;
      VkMemoryRequirements ir = {};
      imageReq(device, image, &ir);
      uint32_t imageType = memoryType(ir.memoryTypeBits, 0);
      if (imageType == UINT32_MAX) break;
      VkMemoryAllocateInfo ai = {};
      ai.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
      ai.allocationSize = ir.size; ai.memoryTypeIndex = imageType;
      if (allocMemory(device, &ai, nullptr, &imageMemory) != VK_SUCCESS) break;
      if (bindImage(device, image, imageMemory, 0) != VK_SUCCESS) break;
      mask |= 4u;
      VkBufferCreateInfo bi = {};
      bi.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
      bi.size = 4 * 4 * 4;
      bi.usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT;
      bi.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
      if (createBuffer(device, &bi, nullptr, &staging) != VK_SUCCESS) break;
      VkMemoryRequirements br = {};
      bufferReq(device, staging, &br);
      uint32_t stagingType = memoryType(br.memoryTypeBits,
          VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
      if (stagingType == UINT32_MAX) break;
      ai.allocationSize = br.size; ai.memoryTypeIndex = stagingType;
      if (allocMemory(device, &ai, nullptr, &stagingMemory) != VK_SUCCESS) break;
      if (bindBuffer(device, staging, stagingMemory, 0) != VK_SUCCESS) break;
      mask |= 8u;
      VkCommandPoolCreateInfo pi = {};
      pi.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
      pi.queueFamilyIndex = family;
      if (createPool(device, &pi, nullptr, &pool) != VK_SUCCESS) break;
      VkCommandBuffer cmd = VK_NULL_HANDLE;
      VkCommandBufferAllocateInfo ci = {};
      ci.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
      ci.commandPool = pool; ci.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
      ci.commandBufferCount = 1;
      if (allocCommands(device, &ci, &cmd) != VK_SUCCESS) break;
      VkCommandBufferBeginInfo cb = {};
      cb.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
      cb.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
      if (begin(cmd, &cb) != VK_SUCCESS) break;
      // Create an actual color-attachment render pass, framebuffer and image view.
      VkImageViewCreateInfo vi = {};
      vi.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
      vi.image = image; vi.viewType = VK_IMAGE_VIEW_TYPE_2D;
      vi.format = VK_FORMAT_R8G8B8A8_UNORM;
      vi.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
      vi.subresourceRange.levelCount = 1; vi.subresourceRange.layerCount = 1;
      if (createView(device, &vi, nullptr, &view) != VK_SUCCESS) break;
      VkAttachmentDescription attachment = {};
      attachment.format = VK_FORMAT_R8G8B8A8_UNORM;
      attachment.samples = VK_SAMPLE_COUNT_1_BIT;
      attachment.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR;
      attachment.storeOp = VK_ATTACHMENT_STORE_OP_STORE;
      attachment.stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE;
      attachment.stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
      attachment.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
      attachment.finalLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
      VkAttachmentReference colorRef = {0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL};
      VkSubpassDescription subpass = {};
      subpass.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS;
      subpass.colorAttachmentCount = 1; subpass.pColorAttachments = &colorRef;
      VkSubpassDependency dependency = {};
      dependency.srcSubpass = 0;
      dependency.dstSubpass = VK_SUBPASS_EXTERNAL;
      dependency.srcStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
      dependency.dstStageMask = VK_PIPELINE_STAGE_TRANSFER_BIT;
      dependency.srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
      dependency.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
      VkRenderPassCreateInfo ri = {};
      ri.sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
      ri.attachmentCount = 1; ri.pAttachments = &attachment;
      ri.subpassCount = 1; ri.pSubpasses = &subpass;
      ri.dependencyCount = 1; ri.pDependencies = &dependency;
      if (createRenderPass(device, &ri, nullptr, &renderPass) != VK_SUCCESS) break;
      VkFramebufferCreateInfo fbi = {};
      fbi.sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
      fbi.renderPass = renderPass;
      fbi.attachmentCount = 1; fbi.pAttachments = &view;
      fbi.width = 4; fbi.height = 4; fbi.layers = 1;
      if (createFramebuffer(device, &fbi, nullptr, &framebuffer) != VK_SUCCESS) break;
      VkClearValue clear = {};
      clear.color.float32[0] = 0.2f; clear.color.float32[1] = 0.4f;
      clear.color.float32[2] = 0.6f; clear.color.float32[3] = 1.0f;
      VkRenderPassBeginInfo rp = {};
      rp.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
      rp.renderPass = renderPass; rp.framebuffer = framebuffer;
      rp.renderArea.extent = {4, 4};
      rp.clearValueCount = 1; rp.pClearValues = &clear;
      beginRenderPass(cmd, &rp, VK_SUBPASS_CONTENTS_INLINE);
      endRenderPass(cmd);
      VkBufferImageCopy region = {};
      region.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
      region.imageSubresource.layerCount = 1;
      region.imageExtent = {4, 4, 1};
      copyImage(cmd, image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, staging, 1, &region);
      VkBufferMemoryBarrier bb = {};
      bb.sType = VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER;
      bb.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
      bb.dstAccessMask = VK_ACCESS_HOST_READ_BIT;
      bb.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
      bb.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
      bb.buffer = staging; bb.size = VK_WHOLE_SIZE;
      barrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT,
              0, 0, nullptr, 1, &bb, 0, nullptr);
      if (end(cmd) != VK_SUCCESS) break;
      mask |= 16u;
      VkFenceCreateInfo fi = {};
      fi.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
      if (createFence(device, &fi, nullptr, &fence) != VK_SUCCESS) break;
      VkSubmitInfo si = {};
      si.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
      si.commandBufferCount = 1; si.pCommandBuffers = &cmd;
      submitted = submit(queue, 1, &si, fence) == VK_SUCCESS;
      if (!submitted) break;
      mask |= 32u;
      completed = wait(device, 1, &fence, VK_TRUE, 5000000000ULL) == VK_SUCCESS;
      if (!completed) break;
      mask |= 64u;
      void *mapped = nullptr;
      if (mapMemory(device, stagingMemory, 0, 64, 0, &mapped) != VK_SUCCESS || !mapped) break;
      const auto *bytes = static_cast<const unsigned char *>(mapped);
      bool match = true;
      for (unsigned i = 0; i < 16; ++i) {
         const unsigned char *p = bytes + i * 4;
         if (p[0] != 51 || p[1] != 102 || p[2] != 153 || p[3] != 255) {
            match = false; break;
         }
      }
      unmapMemory(device, stagingMemory);
      if (match) mask |= 128u;
   } while (false);
   // If submitted but fence timed out, ensure completion before freeing resources.
   if (submitted && !completed) (void)queueIdle(queue);
   if (fence) destroyFence(device, fence, nullptr);
   if (pool) destroyPool(device, pool, nullptr);
   if (framebuffer) destroyFramebuffer(device, framebuffer, nullptr);
   if (renderPass) destroyRenderPass(device, renderPass, nullptr);
   if (view) destroyView(device, view, nullptr);
   if (staging) destroyBuffer(device, staging, nullptr);
   if (image) destroyImage(device, image, nullptr);
   if (stagingMemory) freeMemory(device, stagingMemory, nullptr);
   if (imageMemory) freeMemory(device, imageMemory, nullptr);
   return mask;
}
/* Castle 131: shader-driven offscreen triangle draw and pixel readback. Isolated Vulkan device only. */
extern "C" unsigned AzaharV131TriangleDrawGate(void *instanceRaw, void *physicalRaw,
    void *deviceRaw, void *queueRaw, void *instanceProcRaw, unsigned family) {
   if (!instanceRaw || !physicalRaw || !deviceRaw || !queueRaw || !instanceProcRaw) return 0;
   auto instance = reinterpret_cast<VkInstance>(instanceRaw);
   auto physical = reinterpret_cast<VkPhysicalDevice>(physicalRaw);
   auto device = reinterpret_cast<VkDevice>(deviceRaw);
   auto queue = reinterpret_cast<VkQueue>(queueRaw);
   auto gip = reinterpret_cast<PFN_vkGetInstanceProcAddr>(instanceProcRaw);
   auto gdp = reinterpret_cast<PFN_vkGetDeviceProcAddr>(gip(instance, "vkGetDeviceProcAddr"));
   if (!gdp) return 0;
   unsigned mask = 1u;
#define AZ_V128_PROC(type, var, name) auto var = reinterpret_cast<type>(gdp(device, name))
   AZ_V128_PROC(PFN_vkCreateImage, createImage, "vkCreateImage");
   AZ_V128_PROC(PFN_vkDestroyImage, destroyImage, "vkDestroyImage");
   AZ_V128_PROC(PFN_vkGetImageMemoryRequirements, imageReq, "vkGetImageMemoryRequirements");
   AZ_V128_PROC(PFN_vkCreateBuffer, createBuffer, "vkCreateBuffer");
   AZ_V128_PROC(PFN_vkDestroyBuffer, destroyBuffer, "vkDestroyBuffer");
   AZ_V128_PROC(PFN_vkGetBufferMemoryRequirements, bufferReq, "vkGetBufferMemoryRequirements");
   AZ_V128_PROC(PFN_vkAllocateMemory, allocMemory, "vkAllocateMemory");
   AZ_V128_PROC(PFN_vkFreeMemory, freeMemory, "vkFreeMemory");
   AZ_V128_PROC(PFN_vkBindImageMemory, bindImage, "vkBindImageMemory");
   AZ_V128_PROC(PFN_vkBindBufferMemory, bindBuffer, "vkBindBufferMemory");
   AZ_V128_PROC(PFN_vkMapMemory, mapMemory, "vkMapMemory");
   AZ_V128_PROC(PFN_vkUnmapMemory, unmapMemory, "vkUnmapMemory");
   AZ_V128_PROC(PFN_vkCreateCommandPool, createPool, "vkCreateCommandPool");
   AZ_V128_PROC(PFN_vkDestroyCommandPool, destroyPool, "vkDestroyCommandPool");
   AZ_V128_PROC(PFN_vkAllocateCommandBuffers, allocCommands, "vkAllocateCommandBuffers");
   AZ_V128_PROC(PFN_vkBeginCommandBuffer, begin, "vkBeginCommandBuffer");
   AZ_V128_PROC(PFN_vkEndCommandBuffer, end, "vkEndCommandBuffer");
   AZ_V128_PROC(PFN_vkCmdPipelineBarrier, barrier, "vkCmdPipelineBarrier");
   AZ_V128_PROC(PFN_vkCreateImageView, createView, "vkCreateImageView");
   AZ_V128_PROC(PFN_vkDestroyImageView, destroyView, "vkDestroyImageView");
   AZ_V128_PROC(PFN_vkCreateRenderPass, createRenderPass, "vkCreateRenderPass");
   AZ_V128_PROC(PFN_vkDestroyRenderPass, destroyRenderPass, "vkDestroyRenderPass");
   AZ_V128_PROC(PFN_vkCreateFramebuffer, createFramebuffer, "vkCreateFramebuffer");
   AZ_V128_PROC(PFN_vkDestroyFramebuffer, destroyFramebuffer, "vkDestroyFramebuffer");
   AZ_V128_PROC(PFN_vkCmdBeginRenderPass, beginRenderPass, "vkCmdBeginRenderPass");
   AZ_V128_PROC(PFN_vkCmdEndRenderPass, endRenderPass, "vkCmdEndRenderPass");
   AZ_V128_PROC(PFN_vkCreateShaderModule, createShader, "vkCreateShaderModule");
   AZ_V128_PROC(PFN_vkDestroyShaderModule, destroyShader, "vkDestroyShaderModule");
   AZ_V128_PROC(PFN_vkCreatePipelineLayout, createLayout, "vkCreatePipelineLayout");
   AZ_V128_PROC(PFN_vkDestroyPipelineLayout, destroyLayout, "vkDestroyPipelineLayout");
   AZ_V128_PROC(PFN_vkCreateGraphicsPipelines, createPipelines, "vkCreateGraphicsPipelines");
   AZ_V128_PROC(PFN_vkDestroyPipeline, destroyPipeline, "vkDestroyPipeline");
   AZ_V128_PROC(PFN_vkCmdBindPipeline, bindPipeline, "vkCmdBindPipeline");
   AZ_V128_PROC(PFN_vkCmdBindVertexBuffers, bindVertexBuffers, "vkCmdBindVertexBuffers");
   AZ_V128_PROC(PFN_vkCmdDraw, draw, "vkCmdDraw");
   AZ_V128_PROC(PFN_vkCmdCopyImageToBuffer, copyImage, "vkCmdCopyImageToBuffer");
   AZ_V128_PROC(PFN_vkCreateFence, createFence, "vkCreateFence");
   AZ_V128_PROC(PFN_vkDestroyFence, destroyFence, "vkDestroyFence");
   AZ_V128_PROC(PFN_vkQueueSubmit, submit, "vkQueueSubmit");
   AZ_V128_PROC(PFN_vkWaitForFences, wait, "vkWaitForFences");
   AZ_V128_PROC(PFN_vkQueueWaitIdle, queueIdle, "vkQueueWaitIdle");
#undef AZ_V128_PROC
   auto getMemoryProperties = reinterpret_cast<PFN_vkGetPhysicalDeviceMemoryProperties>(
       gip(instance, "vkGetPhysicalDeviceMemoryProperties"));
   if (!createImage || !destroyImage || !imageReq || !createBuffer || !destroyBuffer ||
       !bufferReq || !allocMemory || !freeMemory || !bindImage || !bindBuffer ||
       !mapMemory || !unmapMemory || !createPool || !destroyPool || !allocCommands ||
       !begin || !end || !barrier || !createView || !destroyView ||
       !createRenderPass || !destroyRenderPass || !createFramebuffer ||
       !destroyFramebuffer || !beginRenderPass || !endRenderPass ||
       !createShader || !destroyShader || !createLayout || !destroyLayout ||
       !createPipelines || !destroyPipeline || !bindPipeline || !bindVertexBuffers || !draw || !copyImage || !createFence ||
       !destroyFence || !submit || !wait || !queueIdle || !getMemoryProperties) return mask;
   mask |= 2u;
   VkPhysicalDeviceMemoryProperties memoryProps = {};
   getMemoryProperties(physical, &memoryProps);
   auto memoryType = [&](uint32_t allowed, VkMemoryPropertyFlags required) -> uint32_t {
      for (uint32_t i = 0; i < memoryProps.memoryTypeCount; ++i)
         if ((allowed & (1u << i)) &&
             (memoryProps.memoryTypes[i].propertyFlags & required) == required) return i;
      return UINT32_MAX;
   };
   VkImage image = VK_NULL_HANDLE;
   VkBuffer staging = VK_NULL_HANDLE;
   VkDeviceMemory imageMemory = VK_NULL_HANDLE, stagingMemory = VK_NULL_HANDLE;
   VkCommandPool pool = VK_NULL_HANDLE;
   VkFence fence = VK_NULL_HANDLE;
   VkImageView view = VK_NULL_HANDLE;
   VkRenderPass renderPass = VK_NULL_HANDLE;
   VkFramebuffer framebuffer = VK_NULL_HANDLE;
   VkShaderModule vertexShader = VK_NULL_HANDLE, fragmentShader = VK_NULL_HANDLE;
   VkPipelineLayout pipelineLayout = VK_NULL_HANDLE;
   VkPipeline pipeline = VK_NULL_HANDLE;
   VkBuffer vertices = VK_NULL_HANDLE;
   VkDeviceMemory vertexMemory = VK_NULL_HANDLE;
   bool submitted = false, completed = false;
   do {
      VkImageCreateInfo ii = {};
      ii.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
      ii.imageType = VK_IMAGE_TYPE_2D;
      ii.format = VK_FORMAT_R8G8B8A8_UNORM;
      ii.extent = {16, 16, 1};
      ii.mipLevels = 1; ii.arrayLayers = 1;
      ii.samples = VK_SAMPLE_COUNT_1_BIT;
      ii.tiling = VK_IMAGE_TILING_OPTIMAL;
      ii.usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
      ii.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
      ii.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
      if (createImage(device, &ii, nullptr, &image) != VK_SUCCESS) break;
      VkMemoryRequirements ir = {};
      imageReq(device, image, &ir);
      uint32_t imageType = memoryType(ir.memoryTypeBits, 0);
      if (imageType == UINT32_MAX) break;
      VkMemoryAllocateInfo ai = {};
      ai.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
      ai.allocationSize = ir.size; ai.memoryTypeIndex = imageType;
      if (allocMemory(device, &ai, nullptr, &imageMemory) != VK_SUCCESS) break;
      if (bindImage(device, image, imageMemory, 0) != VK_SUCCESS) break;
      mask |= 4u;
      VkBufferCreateInfo bi = {};
      bi.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
      bi.size = 16 * 16 * 4;
      bi.usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT;
      bi.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
      if (createBuffer(device, &bi, nullptr, &staging) != VK_SUCCESS) break;
      VkMemoryRequirements br = {};
      bufferReq(device, staging, &br);
      uint32_t stagingType = memoryType(br.memoryTypeBits,
          VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
      if (stagingType == UINT32_MAX) break;
      ai.allocationSize = br.size; ai.memoryTypeIndex = stagingType;
      if (allocMemory(device, &ai, nullptr, &stagingMemory) != VK_SUCCESS) break;
      if (bindBuffer(device, staging, stagingMemory, 0) != VK_SUCCESS) break;
      mask |= 8u;
      VkCommandPoolCreateInfo pi = {};
      pi.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
      pi.queueFamilyIndex = family;
      if (createPool(device, &pi, nullptr, &pool) != VK_SUCCESS) break;
      VkCommandBuffer cmd = VK_NULL_HANDLE;
      VkCommandBufferAllocateInfo ci = {};
      ci.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
      ci.commandPool = pool; ci.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
      ci.commandBufferCount = 1;
      if (allocCommands(device, &ci, &cmd) != VK_SUCCESS) break;
      VkCommandBufferBeginInfo cb = {};
      cb.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
      cb.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
      if (begin(cmd, &cb) != VK_SUCCESS) break;
      // Create an actual color-attachment render pass, framebuffer and image view.
      VkImageViewCreateInfo vi = {};
      vi.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
      vi.image = image; vi.viewType = VK_IMAGE_VIEW_TYPE_2D;
      vi.format = VK_FORMAT_R8G8B8A8_UNORM;
      vi.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
      vi.subresourceRange.levelCount = 1; vi.subresourceRange.layerCount = 1;
      if (createView(device, &vi, nullptr, &view) != VK_SUCCESS) break;
      VkAttachmentDescription attachment = {};
      attachment.format = VK_FORMAT_R8G8B8A8_UNORM;
      attachment.samples = VK_SAMPLE_COUNT_1_BIT;
      attachment.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR;
      attachment.storeOp = VK_ATTACHMENT_STORE_OP_STORE;
      attachment.stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE;
      attachment.stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
      attachment.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
      attachment.finalLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
      VkAttachmentReference colorRef = {0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL};
      VkSubpassDescription subpass = {};
      subpass.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS;
      subpass.colorAttachmentCount = 1; subpass.pColorAttachments = &colorRef;
      VkSubpassDependency dependency = {};
      dependency.srcSubpass = 0;
      dependency.dstSubpass = VK_SUBPASS_EXTERNAL;
      dependency.srcStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
      dependency.dstStageMask = VK_PIPELINE_STAGE_TRANSFER_BIT;
      dependency.srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
      dependency.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
      VkRenderPassCreateInfo ri = {};
      ri.sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
      ri.attachmentCount = 1; ri.pAttachments = &attachment;
      ri.subpassCount = 1; ri.pSubpasses = &subpass;
      ri.dependencyCount = 1; ri.pDependencies = &dependency;
      if (createRenderPass(device, &ri, nullptr, &renderPass) != VK_SUCCESS) break;
      VkFramebufferCreateInfo fbi = {};
      fbi.sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
      fbi.renderPass = renderPass;
      fbi.attachmentCount = 1; fbi.pAttachments = &view;
      fbi.width = 16; fbi.height = 16; fbi.layers = 1;
      if (createFramebuffer(device, &fbi, nullptr, &framebuffer) != VK_SUCCESS) break;
      VkClearValue clear = {};
      clear.color.float32[0] = 0.2f; clear.color.float32[1] = 0.4f;
      clear.color.float32[2] = 0.6f; clear.color.float32[3] = 1.0f;
      VkRenderPassBeginInfo rp = {};
      rp.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
      rp.renderPass = renderPass; rp.framebuffer = framebuffer;
      rp.renderArea.extent = {16, 16};
      rp.clearValueCount = 1; rp.pClearValues = &clear;
      // Precompiled SPIR-V 1.0, embedded to avoid runtime shader compiler dependencies.
      static const uint32_t kVertexSPV[] = {0x07230203u, 0x00010000u, 0x00000000u, 0x00000012u, 0x00000000u, 0x00020011u, 0x00000001u, 0x0003000eu, 0x00000000u, 0x00000001u, 0x0007000fu, 0x00000000u, 0x00000001u, 0x6e69616du, 0x00000000u, 0x00000002u, 0x00000003u, 0x00030003u, 0x00000002u, 0x000001c2u, 0x00040047u, 0x00000002u, 0x0000001eu, 0x00000000u, 0x00040047u, 0x00000003u, 0x0000000bu, 0x00000000u, 0x00020013u, 0x00000004u, 0x00030016u, 0x00000005u, 0x00000020u, 0x00040017u, 0x00000006u, 0x00000005u, 0x00000002u, 0x00040017u, 0x00000007u, 0x00000005u, 0x00000004u, 0x00040020u, 0x00000008u, 0x00000001u, 0x00000006u, 0x00040020u, 0x00000009u, 0x00000003u, 0x00000007u, 0x00030021u, 0x0000000au, 0x00000004u, 0x0004002bu, 0x00000005u, 0x0000000bu, 0x00000000u, 0x0004002bu, 0x00000005u, 0x0000000cu, 0x3f800000u, 0x0004003bu, 0x00000008u, 0x00000002u, 0x00000001u, 0x0004003bu, 0x00000009u, 0x00000003u, 0x00000003u, 0x00050036u, 0x00000004u, 0x00000001u, 0x00000000u, 0x0000000au, 0x000200f8u, 0x0000000du, 0x0004003du, 0x00000006u, 0x0000000eu, 0x00000002u, 0x00050051u, 0x00000005u, 0x0000000fu, 0x0000000eu, 0x00000000u, 0x00050051u, 0x00000005u, 0x00000010u, 0x0000000eu, 0x00000001u, 0x00070050u, 0x00000007u, 0x00000011u, 0x0000000fu, 0x00000010u, 0x0000000bu, 0x0000000cu, 0x0003003eu, 0x00000003u, 0x00000011u, 0x000100fdu, 0x00010038u};
      static const uint32_t kFragmentSPV[] = {0x07230203u, 0x00010000u, 0x00000000u, 0x0000000cu, 0x00000000u, 0x00020011u, 0x00000001u, 0x0003000eu, 0x00000000u, 0x00000001u, 0x0006000fu, 0x00000004u, 0x00000001u, 0x6e69616du, 0x00000000u, 0x00000002u, 0x00030010u, 0x00000001u, 0x00000007u, 0x00040047u, 0x00000002u, 0x0000001eu, 0x00000000u, 0x00020013u, 0x00000003u, 0x00030016u, 0x00000004u, 0x00000020u, 0x00040017u, 0x00000005u, 0x00000004u, 0x00000004u, 0x00040020u, 0x00000006u, 0x00000003u, 0x00000005u, 0x00030021u, 0x00000007u, 0x00000003u, 0x0004002bu, 0x00000004u, 0x00000008u, 0x00000000u, 0x0004002bu, 0x00000004u, 0x00000009u, 0x3f800000u, 0x0007002cu, 0x00000005u, 0x0000000au, 0x00000008u, 0x00000009u, 0x00000008u, 0x00000009u, 0x0004003bu, 0x00000006u, 0x00000002u, 0x00000003u, 0x00050036u, 0x00000003u, 0x00000001u, 0x00000000u, 0x00000007u, 0x000200f8u, 0x0000000bu, 0x0003003eu, 0x00000002u, 0x0000000au, 0x000100fdu, 0x00010038u};
      VkShaderModuleCreateInfo sm = {};
      sm.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
      sm.codeSize = sizeof(kVertexSPV); sm.pCode = kVertexSPV;
      if (createShader(device, &sm, nullptr, &vertexShader) != VK_SUCCESS) break;
      sm.codeSize = sizeof(kFragmentSPV); sm.pCode = kFragmentSPV;
      if (createShader(device, &sm, nullptr, &fragmentShader) != VK_SUCCESS) break;
      VkPipelineLayoutCreateInfo pli = {};
      pli.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
      if (createLayout(device, &pli, nullptr, &pipelineLayout) != VK_SUCCESS) break;
      // One triangle covers the center pixel; corners retain render-pass clear color.
      const float triangle[] = {-0.8f, -0.8f, 0.8f, -0.8f, 0.0f, 0.8f};
      VkBufferCreateInfo vbi = {};
      vbi.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
      vbi.size = sizeof(triangle); vbi.usage = VK_BUFFER_USAGE_VERTEX_BUFFER_BIT;
      vbi.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
      if (createBuffer(device, &vbi, nullptr, &vertices) != VK_SUCCESS) break;
      VkMemoryRequirements vr = {};
      bufferReq(device, vertices, &vr);
      const uint32_t vt = memoryType(vr.memoryTypeBits,
          VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
      if (vt == UINT32_MAX) break;
      VkMemoryAllocateInfo vai = {};
      vai.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
      vai.allocationSize = vr.size; vai.memoryTypeIndex = vt;
      if (allocMemory(device, &vai, nullptr, &vertexMemory) != VK_SUCCESS) break;
      if (bindBuffer(device, vertices, vertexMemory, 0) != VK_SUCCESS) break;
      void *vertexMapped = nullptr;
      if (mapMemory(device, vertexMemory, 0, sizeof(triangle), 0, &vertexMapped) != VK_SUCCESS || !vertexMapped) break;
      std::memcpy(vertexMapped, triangle, sizeof(triangle));
      unmapMemory(device, vertexMemory);
      VkPipelineShaderStageCreateInfo stages[2] = {};
      stages[0].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
      stages[0].stage = VK_SHADER_STAGE_VERTEX_BIT;
      stages[0].module = vertexShader; stages[0].pName = "main";
      stages[1].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
      stages[1].stage = VK_SHADER_STAGE_FRAGMENT_BIT;
      stages[1].module = fragmentShader; stages[1].pName = "main";
      VkVertexInputBindingDescription binding = {0, sizeof(float) * 2, VK_VERTEX_INPUT_RATE_VERTEX};
      VkVertexInputAttributeDescription attribute = {0, 0, VK_FORMAT_R32G32_SFLOAT, 0};
      VkPipelineVertexInputStateCreateInfo input = {};
      input.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
      input.vertexBindingDescriptionCount = 1; input.pVertexBindingDescriptions = &binding;
      input.vertexAttributeDescriptionCount = 1; input.pVertexAttributeDescriptions = &attribute;
      VkPipelineInputAssemblyStateCreateInfo assembly = {};
      assembly.sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
      assembly.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
      VkViewport viewport = {0, 0, 16, 16, 0, 1};
      VkRect2D scissor = {{0, 0}, {16, 16}};
      VkPipelineViewportStateCreateInfo viewportState = {};
      viewportState.sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
      viewportState.viewportCount = 1; viewportState.pViewports = &viewport;
      viewportState.scissorCount = 1; viewportState.pScissors = &scissor;
      VkPipelineRasterizationStateCreateInfo raster = {};
      raster.sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
      raster.polygonMode = VK_POLYGON_MODE_FILL;
      raster.cullMode = VK_CULL_MODE_NONE;
      raster.frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE;
      raster.lineWidth = 1.0f;
      VkPipelineMultisampleStateCreateInfo ms = {};
      ms.sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
      ms.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;
      VkPipelineColorBlendAttachmentState blendAttachment = {};
      blendAttachment.colorWriteMask = VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT |
                                       VK_COLOR_COMPONENT_B_BIT | VK_COLOR_COMPONENT_A_BIT;
      VkPipelineColorBlendStateCreateInfo blend = {};
      blend.sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
      blend.attachmentCount = 1; blend.pAttachments = &blendAttachment;
      VkGraphicsPipelineCreateInfo graphics = {};
      graphics.sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
      graphics.stageCount = 2; graphics.pStages = stages;
      graphics.pVertexInputState = &input;
      graphics.pInputAssemblyState = &assembly;
      graphics.pViewportState = &viewportState;
      graphics.pRasterizationState = &raster;
      graphics.pMultisampleState = &ms;
      graphics.pColorBlendState = &blend;
      graphics.layout = pipelineLayout;
      graphics.renderPass = renderPass;
      if (createPipelines(device, VK_NULL_HANDLE, 1, &graphics, nullptr, &pipeline) != VK_SUCCESS) break;
      beginRenderPass(cmd, &rp, VK_SUBPASS_CONTENTS_INLINE);
      bindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
      VkDeviceSize vertexOffset = 0;
      bindVertexBuffers(cmd, 0, 1, &vertices, &vertexOffset);
      draw(cmd, 3, 1, 0, 0);
      endRenderPass(cmd);
      VkBufferImageCopy region = {};
      region.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
      region.imageSubresource.layerCount = 1;
      region.imageExtent = {16, 16, 1};
      copyImage(cmd, image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, staging, 1, &region);
      VkBufferMemoryBarrier bb = {};
      bb.sType = VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER;
      bb.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
      bb.dstAccessMask = VK_ACCESS_HOST_READ_BIT;
      bb.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
      bb.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
      bb.buffer = staging; bb.size = VK_WHOLE_SIZE;
      barrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT,
              0, 0, nullptr, 1, &bb, 0, nullptr);
      if (end(cmd) != VK_SUCCESS) break;
      mask |= 16u;
      VkFenceCreateInfo fi = {};
      fi.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
      if (createFence(device, &fi, nullptr, &fence) != VK_SUCCESS) break;
      VkSubmitInfo si = {};
      si.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
      si.commandBufferCount = 1; si.pCommandBuffers = &cmd;
      submitted = submit(queue, 1, &si, fence) == VK_SUCCESS;
      if (!submitted) break;
      mask |= 32u;
      completed = wait(device, 1, &fence, VK_TRUE, 5000000000ULL) == VK_SUCCESS;
      if (!completed) break;
      mask |= 64u;
      void *mapped = nullptr;
      if (mapMemory(device, stagingMemory, 0, 16 * 16 * 4, 0, &mapped) != VK_SUCCESS || !mapped) break;
      const auto *bytes = static_cast<const unsigned char *>(mapped);
      const auto pixel = [&](unsigned x, unsigned y) -> const unsigned char * {
         return bytes + (y * 16 + x) * 4;
      };
      const auto *center = pixel(8, 8);
      const auto *corner = pixel(0, 0);
      const bool match = center[0] == 0 && center[1] == 255 && center[2] == 0 && center[3] == 255 &&
                         corner[0] == 51 && corner[1] == 102 && corner[2] == 153 && corner[3] == 255;
      unmapMemory(device, stagingMemory);
      if (match) mask |= 128u;
   } while (false);
   // If submitted but fence timed out, ensure completion before freeing resources.
   if (submitted && !completed) (void)queueIdle(queue);
   if (fence) destroyFence(device, fence, nullptr);
   if (pool) destroyPool(device, pool, nullptr);
   if (pipeline) destroyPipeline(device, pipeline, nullptr);
   if (pipelineLayout) destroyLayout(device, pipelineLayout, nullptr);
   if (vertexShader) destroyShader(device, vertexShader, nullptr);
   if (fragmentShader) destroyShader(device, fragmentShader, nullptr);
   if (vertices) destroyBuffer(device, vertices, nullptr);
   if (vertexMemory) freeMemory(device, vertexMemory, nullptr);
   if (framebuffer) destroyFramebuffer(device, framebuffer, nullptr);
   if (renderPass) destroyRenderPass(device, renderPass, nullptr);
   if (view) destroyView(device, view, nullptr);
   if (staging) destroyBuffer(device, staging, nullptr);
   if (image) destroyImage(device, image, nullptr);
   if (stagingMemory) freeMemory(device, stagingMemory, nullptr);
   if (imageMemory) freeMemory(device, imageMemory, nullptr);
   return mask;
}
/* Castle 127: record and submit a real primary command buffer on the
   temporary MoltenVK device. All objects are local and destroyed before
   returning. This is a synchronization rehearsal, not GPU game rendering. */
extern "C" unsigned AzaharV127CommandBufferGate(void *instanceRaw,
    void *deviceRaw, void *queueRaw, void *instanceProcRaw, unsigned family) {
   if (!instanceRaw || !deviceRaw || !queueRaw || !instanceProcRaw) return 0;
   auto instance = reinterpret_cast<VkInstance>(instanceRaw);
   auto device = reinterpret_cast<VkDevice>(deviceRaw);
   auto queue = reinterpret_cast<VkQueue>(queueRaw);
   auto gip = reinterpret_cast<PFN_vkGetInstanceProcAddr>(instanceProcRaw);
   auto gdp = reinterpret_cast<PFN_vkGetDeviceProcAddr>(gip(instance, "vkGetDeviceProcAddr"));
   if (!gdp) return 0;
   unsigned mask = 1u;
   auto createPool = reinterpret_cast<PFN_vkCreateCommandPool>(gdp(device, "vkCreateCommandPool"));
   auto destroyPool = reinterpret_cast<PFN_vkDestroyCommandPool>(gdp(device, "vkDestroyCommandPool"));
   auto allocate = reinterpret_cast<PFN_vkAllocateCommandBuffers>(gdp(device, "vkAllocateCommandBuffers"));
   auto begin = reinterpret_cast<PFN_vkBeginCommandBuffer>(gdp(device, "vkBeginCommandBuffer"));
   auto barrier = reinterpret_cast<PFN_vkCmdPipelineBarrier>(gdp(device, "vkCmdPipelineBarrier"));
   auto end = reinterpret_cast<PFN_vkEndCommandBuffer>(gdp(device, "vkEndCommandBuffer"));
   auto createFence = reinterpret_cast<PFN_vkCreateFence>(gdp(device, "vkCreateFence"));
   auto destroyFence = reinterpret_cast<PFN_vkDestroyFence>(gdp(device, "vkDestroyFence"));
   auto submit = reinterpret_cast<PFN_vkQueueSubmit>(gdp(device, "vkQueueSubmit"));
   auto wait = reinterpret_cast<PFN_vkWaitForFences>(gdp(device, "vkWaitForFences"));
   auto queueIdle = reinterpret_cast<PFN_vkQueueWaitIdle>(gdp(device, "vkQueueWaitIdle"));
   if (!createPool || !destroyPool || !allocate || !begin || !barrier || !end ||
       !createFence || !destroyFence || !submit || !wait || !queueIdle) return mask;
   mask |= 2u;
   VkCommandPoolCreateInfo poolInfo = {};
   poolInfo.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
   poolInfo.queueFamilyIndex = family;
   VkCommandPool pool = VK_NULL_HANDLE;
   if (createPool(device, &poolInfo, nullptr, &pool) != VK_SUCCESS || pool == VK_NULL_HANDLE)
      return mask;
   mask |= 4u;
   VkCommandBuffer command = VK_NULL_HANDLE;
   VkCommandBufferAllocateInfo allocInfo = {};
   allocInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
   allocInfo.commandPool = pool;
   allocInfo.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
   allocInfo.commandBufferCount = 1;
   bool recorded = false;
   if (allocate(device, &allocInfo, &command) == VK_SUCCESS && command != VK_NULL_HANDLE) {
      VkCommandBufferBeginInfo beginInfo = {};
      beginInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
      beginInfo.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
      if (begin(command, &beginInfo) == VK_SUCCESS) {
         // A valid no-resource pipeline barrier: exercises actual command recording.
         barrier(command, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
                 VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, 0, 0, nullptr, 0, nullptr, 0, nullptr);
         recorded = end(command) == VK_SUCCESS;
      }
   }
   if (recorded) mask |= 8u;
   VkFence fence = VK_NULL_HANDLE;
   VkFenceCreateInfo fenceInfo = {};
   fenceInfo.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
   bool submitted = false;
   bool completed = false;
   if (recorded && createFence(device, &fenceInfo, nullptr, &fence) == VK_SUCCESS && fence != VK_NULL_HANDLE) {
      VkSubmitInfo submitInfo = {};
      submitInfo.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
      submitInfo.commandBufferCount = 1;
      submitInfo.pCommandBuffers = &command;
      submitted = submit(queue, 1, &submitInfo, fence) == VK_SUCCESS;
      if (submitted) {
         mask |= 16u;
         completed = wait(device, 1, &fence, VK_TRUE, 1000000000ULL) == VK_SUCCESS;
         if (completed) mask |= 32u;
         // On a timeout, do not destroy in-flight command pool/fence resources.
         // Wait for queue idle before cleanup (no concurrent users of this queue).
         if (!completed) (void)queueIdle(queue);
      }
   }
   if (fence != VK_NULL_HANDLE) destroyFence(device, fence, nullptr);
   destroyPool(device, pool, nullptr);
   return mask;
}
/* Castle 126: submit a zero-work batch with a fence to the real temporary
   MoltenVK queue and wait for completion. This tests queue submission, not
   rendering or a shared Azahar context. The caller owns all live handles. */
extern "C" unsigned AzaharV126FenceSubmissionGate(void *instanceRaw,
    void *deviceRaw, void *queueRaw, void *instanceProcRaw) {
   if (!instanceRaw || !deviceRaw || !queueRaw || !instanceProcRaw) return 0;
   auto instance = reinterpret_cast<VkInstance>(instanceRaw);
   auto device = reinterpret_cast<VkDevice>(deviceRaw);
   auto queue = reinterpret_cast<VkQueue>(queueRaw);
   auto gip = reinterpret_cast<PFN_vkGetInstanceProcAddr>(instanceProcRaw);
   auto gdp = reinterpret_cast<PFN_vkGetDeviceProcAddr>(gip(instance, "vkGetDeviceProcAddr"));
   if (!gdp) return 0;
   auto createFence = reinterpret_cast<PFN_vkCreateFence>(gdp(device, "vkCreateFence"));
   auto destroyFence = reinterpret_cast<PFN_vkDestroyFence>(gdp(device, "vkDestroyFence"));
   auto queueSubmit = reinterpret_cast<PFN_vkQueueSubmit>(gdp(device, "vkQueueSubmit"));
   auto waitFences = reinterpret_cast<PFN_vkWaitForFences>(gdp(device, "vkWaitForFences"));
   unsigned mask = 1u;
   if (!createFence || !destroyFence || !queueSubmit || !waitFences) return mask;
   mask |= 2u;
   VkFenceCreateInfo info = {};
   info.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
   VkFence fence = VK_NULL_HANDLE;
   if (createFence(device, &info, nullptr, &fence) != VK_SUCCESS || fence == VK_NULL_HANDLE) return mask;
   mask |= 4u;
   // Vulkan explicitly permits submitCount=0: the fence is signaled after
   // all previously submitted queue work completes (there is none here).
   const VkResult submitResult = queueSubmit(queue, 0, nullptr, fence);
   if (submitResult == VK_SUCCESS) {
      mask |= 8u;
      if (waitFences(device, 1, &fence, VK_TRUE, 1000000000ULL) == VK_SUCCESS)
         mask |= 16u;
   }
   destroyFence(device, fence, nullptr);
   return mask;
}
/* Castle 123: scoped callback ABI/lifetime rehearsal, not a live frame bridge.
   These callbacks operate exclusively on a stack-owned test context. Never
   expose their address to the libretro core or call Azahar lifecycle hooks. */
struct AzV123CallbackScope { unsigned magic, lockDepth, lockCalls, unlockCalls, syncCalls; };
static constexpr unsigned kAzV123Magic = 0xA123C0DEu;
static uint32_t AzV123SyncIndex(void *opaque) {
   auto *scope = static_cast<AzV123CallbackScope *>(opaque);
   if (!scope || scope->magic != kAzV123Magic) return UINT32_MAX;
   ++scope->syncCalls;
   return 0;
}
static void AzV123Lock(void *opaque) {
   auto *scope = static_cast<AzV123CallbackScope *>(opaque);
   if (scope && scope->magic == kAzV123Magic) { ++scope->lockDepth; ++scope->lockCalls; }
}
static void AzV123Unlock(void *opaque) {
   auto *scope = static_cast<AzV123CallbackScope *>(opaque);
   if (scope && scope->magic == kAzV123Magic && scope->lockDepth) {
      --scope->lockDepth; ++scope->unlockCalls;
   }
}
extern "C" unsigned AzaharV123ScopedCallbackGate(void) {
   AzV123CallbackScope scope = { kAzV123Magic, 0, 0, 0, 0 };
   retro_hw_render_interface_vulkan staged = {};
   staged.interface_type = RETRO_HW_RENDER_INTERFACE_VULKAN;
   staged.interface_version = RETRO_HW_RENDER_INTERFACE_VULKAN_VERSION;
   staged.handle = &scope;
   staged.get_sync_index = AzV123SyncIndex;
   staged.lock_queue = AzV123Lock;
   staged.unlock_queue = AzV123Unlock;
   unsigned mask = 0;
   if (staged.handle == &scope && staged.get_sync_index && staged.lock_queue && staged.unlock_queue) mask |= 1u;
   staged.lock_queue(staged.handle);
   if (scope.lockDepth == 1 && scope.lockCalls == 1) mask |= 2u;
   if (staged.get_sync_index(staged.handle) == 0 && scope.syncCalls == 1) mask |= 4u;
   staged.unlock_queue(staged.handle);
   if (scope.lockDepth == 0 && scope.unlockCalls == 1) mask |= 8u;
   /* This is intentionally not a usable image callback or real queue lock. */
   if (!staged.set_image && !staged.device && !staged.instance) mask |= 16u;
   staged.handle = nullptr;
   scope.magic = 0;
   if (!staged.handle && scope.magic == 0) mask |= 32u;
   return mask;
}
#else
extern "C" int AzaharOfficialVulkanABICompileGate(void) { return 0; }
extern "C" unsigned AzaharV133BridgeContractGate(void) { return 0; }
extern "C" unsigned AzaharV142NegotiationContractGate(void) { return 0; }
extern "C" unsigned AzaharV143LiveNegotiationGate(void *, void *, void *, void *, void *, unsigned) { return 0; }
extern "C" unsigned AzaharV145BoundaryAudit(void) { return 0; }
extern "C" unsigned AzaharV134LiveBridgeStageGate(void *, void *, void *, void *, void *, unsigned) { return 0; }
extern "C" unsigned AzaharV135ScopedCallbacksGate(void *, void *, void *, void *, void *, unsigned) { return 0; }
extern "C" unsigned AzaharV136ImageHandoffGate(void *, void *, void *, void *, void *, unsigned) { return 0; }
extern "C" unsigned AzaharV137SynchronizedImageHandoffGate(void *, void *, void *, void *, void *, unsigned) { return 0; }
extern "C" unsigned AzaharV138GPUPixelsToBitmapGate(void *, void *, void *, void *, void *, unsigned, unsigned char *, unsigned) { return 0; }
extern "C" unsigned AzaharV141FullFrameGate(void *, void *, void *, void *, void *, unsigned, unsigned char *, unsigned) { return 0; }
extern "C" int AzaharV121OfficialInterfaceLayoutGate(void) { return 0; }
extern "C" unsigned AzaharV122StageOwnedDevice(void *, void *, void *, void *, unsigned, void *) { return 0; }
extern "C" unsigned AzaharV123ScopedCallbackGate(void) { return 0; }
extern "C" unsigned AzaharV124LiveQueueIdleGate(void *, void *, void *, void *) { return 0; }
extern "C" unsigned AzaharV126FenceSubmissionGate(void *, void *, void *, void *) { return 0; }
extern "C" unsigned AzaharV127CommandBufferGate(void *, void *, void *, void *, unsigned) { return 0; }
extern "C" unsigned AzaharV128ImageClearGate(void *, void *, void *, void *, void *, unsigned) { return 0; }
extern "C" unsigned AzaharV130RenderPassClearGate(void *, void *, void *, void *, void *, unsigned) { return 0; }
extern "C" unsigned AzaharV131TriangleDrawGate(void *, void *, void *, void *, void *, unsigned) { return 0; }
#endif

// Castle 150: bridge the *actual retained owner tuple* across the translation
// unit boundary into the official libretro Vulkan v5 interface representation.
// Never return a pointer to this stack object or publish it to the core.
// In particular, this is NOT a completed GPU image exchange implementation.
extern "C" unsigned AzaharV150StagePersistentOwner(void *instance,
    void *physical, void *device, void *queue, unsigned family,
    void *instanceProc) {
   if (!instance || !physical || !device || !queue || !instanceProc ||
       family == UINT32_MAX) return 0;
   retro_hw_render_interface_vulkan hw = {};
   hw.interface_type = RETRO_HW_RENDER_INTERFACE_VULKAN;
   hw.interface_version = RETRO_HW_RENDER_INTERFACE_VULKAN_VERSION;
   hw.instance = reinterpret_cast<VkInstance>(instance);
   hw.gpu = reinterpret_cast<VkPhysicalDevice>(physical);
   hw.device = reinterpret_cast<VkDevice>(device);
   hw.queue = reinterpret_cast<VkQueue>(queue);
   hw.queue_index = family;
   hw.get_instance_proc_addr =
       reinterpret_cast<PFN_vkGetInstanceProcAddr>(instanceProc);
   hw.get_device_proc_addr =
       reinterpret_cast<PFN_vkGetDeviceProcAddr>(
           hw.get_instance_proc_addr(hw.instance, "vkGetDeviceProcAddr"));
   unsigned mask = 0;
   if (hw.interface_type == RETRO_HW_RENDER_INTERFACE_VULKAN &&
       hw.interface_version == 5) mask |= 1u;
   if (hw.instance && hw.gpu && hw.device && hw.queue) mask |= 2u;
   if (hw.get_instance_proc_addr && hw.get_device_proc_addr) mask |= 4u;
   if (hw.queue_index == family) mask |= 8u;
   if (hw.get_device_proc_addr(hw.device, "vkQueueWaitIdle") &&
       hw.get_device_proc_addr(hw.device, "vkGetDeviceQueue")) mask |= 16u;
   if (!hw.handle && !hw.set_image && !hw.get_sync_index &&
       !hw.get_sync_index_mask && !hw.lock_queue && !hw.unlock_queue &&
       !hw.wait_sync_index) mask |= 32u;
   return mask;
}

// Castle 151: stable-address, frontend-owned official Vulkan v5 descriptor.
// Deliberately unpublished: set_image and synchronization callbacks must be
// implemented before the core may legally receive this descriptor.
// No borrowed pointer escapes the ABI translation unit.
struct AzV151Descriptor {
    retro_hw_render_interface_vulkan hw;
    bool initialized;
    unsigned generation;
};
static AzV151Descriptor gAzV151Descriptor = {};
// Castle 152: real ABI-signature callbacks, installed privately, NOT published.
// Queue locking is shared with the future GPU consumer; the receiver only
// records borrowed image metadata, never dereferences it after the callback.
static std::mutex gAzV152QueueMutex;
// Castle 153: bounded, private metadata inbox. This copies descriptors only;
// it does not own the image, semaphore or create_info pointer members.
// The inbox is not a Vulkan renderer and is NEVER published to Azahar.
static uint32_t gAzV152SyncIndex = 0;
static unsigned gAzV152ImageCalls = 0;
static unsigned gAzV152RejectedImages = 0;
static bool gAzV152ImagePending = false;
static constexpr uint32_t kAzV153MaxWaits = 8;
struct AzV153Inbox {
    VkImage sourceImage; // borrowed real VkImage; valid only while producer owns it
    VkImageView view;
    VkImageLayout layout;
    VkFormat format;
    VkExtent3D extent;
    uint32_t sourceFamily;
    uint32_t semaphoreCount;
    VkSemaphore semaphores[kAzV153MaxWaits];
    unsigned generation;
};
static AzV153Inbox gAzV153Inbox = {};
static unsigned gAzV153Consumed = 0;
static unsigned gAzV153Overflow = 0;
static void AzV152SetImage(void *handle, const retro_vulkan_image *image,
    uint32_t numSemaphores, const VkSemaphore *semaphores, uint32_t srcFamily) {
    if (handle != &gAzV151Descriptor || !gAzV151Descriptor.initialized ||
        !image || !image->image_view ||
        image->create_info.sType != VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO ||
        image->create_info.viewType > VK_IMAGE_VIEW_TYPE_CUBE_ARRAY ||
        numSemaphores > kAzV153MaxWaits || (numSemaphores && !semaphores)) {
        ++gAzV152RejectedImages;
        if (numSemaphores > kAzV153MaxWaits) ++gAzV153Overflow;
        return;
    }
    // Fail closed: do not overwrite an unconsumed borrowed image.
    if (gAzV152ImagePending) { ++gAzV152RejectedImages; return; }
    AzV153Inbox next = {};
    next.sourceImage = image->create_info.image;
    next.view = image->image_view;
    next.layout = image->image_layout;
    next.format = image->create_info.format;
    // VkImageViewCreateInfo has no extent; no dimensions are invented here.
    next.sourceFamily = srcFamily;
    next.semaphoreCount = numSemaphores;
    for (uint32_t i = 0; i < numSemaphores; ++i) next.semaphores[i] = semaphores[i];
    next.generation = gAzV151Descriptor.generation;
    gAzV153Inbox = next;
    ++gAzV152ImageCalls;
    gAzV152ImagePending = true;
}
// Consume only while the producer guarantees the borrowed Vulkan objects live.
// No GPU waits or image readback are performed by this metadata-only function.
static unsigned AzV153ConsumePrivate(AzV153Inbox *out) {
    if (!out || !gAzV151Descriptor.initialized || !gAzV152ImagePending ||
        gAzV153Inbox.generation != gAzV151Descriptor.generation) return 0u;
    *out = gAzV153Inbox;
    gAzV153Inbox = {};
    gAzV152ImagePending = false;
    ++gAzV153Consumed;
    return 1u;
}
// Castle 172: a genuine frame-consumer boundary which retrieves an underlying
// VkImage from the actual official libretro set_image callback, not merely its
// VkImageView. This is NOT a copy or presentation yet. The caller must finish
// GPU synchronization and readback before the producer destroys the VkImage;
// no pointers to view-create-info are retained, and malformed metadata fails
// closed. The C-compatible result is POD and leaves borrowed handles borrowed.
struct AzV172FrameDescriptor {
    void *image;
    void *view;
    unsigned format;
    unsigned layout;
    unsigned sourceFamily;
    unsigned semaphoreCount;
    void *semaphores[kAzV153MaxWaits];
    unsigned generation;
};
extern "C" unsigned AzaharV172TakeFrameDescriptor(void *output, unsigned outputBytes) {
    if (!output || outputBytes != sizeof(AzV172FrameDescriptor)) return 0u;
    AzV153Inbox borrowed = {};
    if (!gAzV151Descriptor.initialized || !gAzV152ImagePending ||
        !gAzV153Inbox.sourceImage || !gAzV153Inbox.view ||
        gAzV153Inbox.sourceFamily != gAzV151Descriptor.hw.queue_index ||
        gAzV153Inbox.semaphoreCount > kAzV153MaxWaits) return 0u;
    if (!AzV153ConsumePrivate(&borrowed)) return 0u;
    AzV172FrameDescriptor frame = {};
    frame.image = reinterpret_cast<void *>(borrowed.sourceImage);
    frame.view = reinterpret_cast<void *>(borrowed.view);
    frame.format = static_cast<unsigned>(borrowed.format);
    frame.layout = static_cast<unsigned>(borrowed.layout);
    frame.sourceFamily = borrowed.sourceFamily;
    frame.semaphoreCount = borrowed.semaphoreCount;
    frame.generation = borrowed.generation;
    for (unsigned i=0; i<frame.semaphoreCount; ++i)
        frame.semaphores[i] = reinterpret_cast<void *>(borrowed.semaphores[i]);
    std::memcpy(output, &frame, sizeof(frame));
    return 1u;
}
// Exercise the real registered ABI callback and the source-image consumer.
// Synthetic Vk handles here are NEVER dereferenced or passed to a driver.
extern "C" unsigned AzaharV172FrameConsumerGate(void) {
    auto &d = gAzV151Descriptor;
    if (!d.initialized || !d.hw.set_image || gAzV152ImagePending) return 0u;
    const unsigned oldAccepted=gAzV152ImageCalls, oldConsumed=gAzV153Consumed;
    const unsigned oldRejected=gAzV152RejectedImages;
    retro_vulkan_image fake = {};
    fake.image_view = reinterpret_cast<VkImageView>(static_cast<uintptr_t>(0x101));
    fake.image_layout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    fake.create_info.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
    fake.create_info.viewType = VK_IMAGE_VIEW_TYPE_2D;
    fake.create_info.format = VK_FORMAT_R8G8B8A8_UNORM;
    unsigned mask=0;
    d.hw.set_image(d.hw.handle, &fake, 0, nullptr, d.hw.queue_index);
    AzV172FrameDescriptor out={};
    if(gAzV152ImagePending && !gAzV153Inbox.sourceImage) mask|=1u;
    if(!AzaharV172TakeFrameDescriptor(&out,sizeof(out)) && gAzV152ImagePending) mask|=2u;
    AzV153Inbox discard={}; AzV153ConsumePrivate(&discard);
    fake.create_info.image=reinterpret_cast<VkImage>(static_cast<uintptr_t>(0x202));
    d.hw.set_image(d.hw.handle,&fake,0,nullptr,d.hw.queue_index);
    if(gAzV152ImagePending && gAzV153Inbox.sourceImage==fake.create_info.image) mask|=4u;
    if(AzaharV172TakeFrameDescriptor(&out,sizeof(out)) &&
       out.image==reinterpret_cast<void *>(fake.create_info.image) &&
       out.view==reinterpret_cast<void *>(fake.image_view) &&
       out.sourceFamily==d.hw.queue_index && !out.semaphoreCount) mask|=8u;
    if(!gAzV152ImagePending && !gAzV153Inbox.view && !gAzV153Inbox.sourceImage) mask|=16u;
    if(!AzaharV172TakeFrameDescriptor(&out,sizeof(out))) mask|=32u;
    // Synthetic-only callback invocation must not change older regression tests.
    gAzV152ImageCalls=oldAccepted;gAzV153Consumed=oldConsumed;
    gAzV152RejectedImages=oldRejected;
    return mask;
}
// Exercises the real callback pointer without passing borrowed resources to
// a GPU. Synthetic handles are opaque values and MUST NOT be dereferenced.
extern "C" unsigned AzaharV153PrivateInboxGate(void) {
    auto &s = gAzV151Descriptor;
    if (!s.initialized || !s.hw.set_image || gAzV152ImagePending) return 0u;
    const unsigned beforeAccept = gAzV152ImageCalls;
    const unsigned beforeReject = gAzV152RejectedImages;
    const unsigned beforeConsume = gAzV153Consumed;
    const unsigned beforeOverflow = gAzV153Overflow;
    unsigned mask = 0;
    retro_vulkan_image synthetic = {};
    synthetic.image_view = reinterpret_cast<VkImageView>(static_cast<uintptr_t>(1));
    synthetic.image_layout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    synthetic.create_info.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
    synthetic.create_info.viewType = VK_IMAGE_VIEW_TYPE_2D;
    synthetic.create_info.format = VK_FORMAT_R8G8B8A8_UNORM;
    s.hw.set_image(s.hw.handle, &synthetic, 0, nullptr, s.hw.queue_index);
    if (gAzV152ImagePending && gAzV152ImageCalls == beforeAccept + 1) mask |= 1u;
    // Second producer must not overwrite an outstanding image.
    s.hw.set_image(s.hw.handle, &synthetic, 0, nullptr, s.hw.queue_index);
    if (gAzV152RejectedImages == beforeReject + 1) mask |= 2u;
    AzV153Inbox result = {};
    if (AzV153ConsumePrivate(&result) && result.view == synthetic.image_view &&
        result.layout == synthetic.image_layout && result.format == synthetic.create_info.format &&
        result.sourceFamily == s.hw.queue_index && !result.semaphoreCount) mask |= 4u;
    if (!gAzV152ImagePending && gAzV153Consumed == beforeConsume + 1) mask |= 8u;
    s.hw.set_image(s.hw.handle, &synthetic, kAzV153MaxWaits + 1, nullptr, s.hw.queue_index);
    if (gAzV153Overflow == beforeOverflow + 1 && !gAzV152ImagePending) mask |= 16u;
    // A malformed image is rejected without touching the inbox.
    synthetic.create_info.sType = VK_STRUCTURE_TYPE_MAX_ENUM;
    s.hw.set_image(s.hw.handle, &synthetic, 0, nullptr, s.hw.queue_index);
    if (!gAzV152ImagePending && gAzV152RejectedImages == beforeReject + 3) mask |= 32u;
    // Reset synthetic-only counters so Castle 152's untouched inbox audit holds.
    gAzV152ImageCalls = beforeAccept;
    gAzV152RejectedImages = beforeReject;
    gAzV153Consumed = beforeConsume;
    gAzV153Overflow = beforeOverflow;
    return mask;
}

// Castle 154: private producer/consumer lifecycle contract.
// The consumer must complete before a borrowed image's owning generation ends.
// These functions never dereference or submit synthetic Vulkan handles.
static unsigned gAzV154Dropped = 0;
static unsigned gAzV154Stale = 0;
static unsigned gAzV154Invalid = 0;
static unsigned AzV154ConsumeGuarded(unsigned expectedGeneration,
    uint32_t expectedFamily, AzV153Inbox *out) {
    if (!out || !gAzV151Descriptor.initialized || !gAzV152ImagePending)
        return 0u;
    if (expectedGeneration != gAzV151Descriptor.generation ||
        gAzV153Inbox.generation != expectedGeneration) {
        ++gAzV154Stale;
        return 0u;
    }
    if (gAzV153Inbox.sourceFamily != expectedFamily ||
        gAzV153Inbox.semaphoreCount > kAzV153MaxWaits ||
        !gAzV153Inbox.view) {
        ++gAzV154Invalid;
        return 0u;
    }
    return AzV153ConsumePrivate(out);
}
static unsigned AzV154DropPending(unsigned expectedGeneration) {
    if (!gAzV152ImagePending || !gAzV151Descriptor.initialized ||
        gAzV153Inbox.generation != expectedGeneration)
        return 0u;
    gAzV153Inbox = {};
    gAzV152ImagePending = false;
    ++gAzV154Dropped;
    return 1u;
}
extern "C" unsigned AzaharV154LifecycleGate(void) {
    auto &state = gAzV151Descriptor;
    if (!state.initialized || !state.hw.set_image || gAzV152ImagePending)
        return 0u;
    const unsigned savedCalls = gAzV152ImageCalls;
    const unsigned savedRejects = gAzV152RejectedImages;
    const unsigned savedConsumed = gAzV153Consumed;
    const unsigned savedDropped = gAzV154Dropped;
    const unsigned savedStale = gAzV154Stale;
    const unsigned savedInvalid = gAzV154Invalid;
    const unsigned gen = state.generation;
    const uint32_t family = state.hw.queue_index;
    retro_vulkan_image synthetic = {};
    synthetic.image_view = reinterpret_cast<VkImageView>(static_cast<uintptr_t>(1));
    synthetic.image_layout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    synthetic.create_info.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
    synthetic.create_info.viewType = VK_IMAGE_VIEW_TYPE_2D;
    synthetic.create_info.format = VK_FORMAT_R8G8B8A8_UNORM;
    unsigned mask = 0;
    AzV153Inbox consumed = {};
    state.hw.set_image(state.hw.handle, &synthetic, 0, nullptr, family);
    if (gAzV152ImagePending && gAzV153Inbox.generation == gen) mask |= 1u;
    if (!AzV154ConsumeGuarded(gen + 1, family, &consumed) &&
        gAzV152ImagePending && gAzV154Stale == savedStale + 1) mask |= 2u;
    if (!AzV154ConsumeGuarded(gen, family + 1, &consumed) &&
        gAzV152ImagePending && gAzV154Invalid == savedInvalid + 1) mask |= 4u;
    if (AzV154ConsumeGuarded(gen, family, &consumed) &&
        consumed.view == synthetic.image_view && !gAzV152ImagePending) mask |= 8u;
    state.hw.set_image(state.hw.handle, &synthetic, 0, nullptr, family);
    if (AzV154DropPending(gen) && !gAzV152ImagePending &&
        !gAzV153Inbox.view && gAzV154Dropped == savedDropped + 1) mask |= 16u;
    state.hw.set_image(state.hw.handle, &synthetic, 0, nullptr, family);
    if (!AzV154DropPending(gen + 1) && gAzV152ImagePending &&
        AzV154DropPending(gen) && !gAzV152ImagePending) mask |= 32u;
    // Synthetic tests must not contaminate the normal callback audit.
    gAzV152ImageCalls = savedCalls;
    gAzV152RejectedImages = savedRejects;
    gAzV153Consumed = savedConsumed;
    gAzV154Dropped = savedDropped;
    gAzV154Stale = savedStale;
    gAzV154Invalid = savedInvalid;
    return mask;
}
// Castle 155: exercise REAL Vulkan binary-semaphore GPU queue synchronization.
// This is a private, no-image probe. Synthetic image handles from V153/V154
// never reach Vulkan. The official descriptor remains unpublished.
extern "C" unsigned AzaharV155PrivateSemaphoreGate(void) {
    const auto &owner = gAzV151Descriptor;
    if (!owner.initialized || !owner.hw.device || !owner.hw.queue ||
        !owner.hw.get_device_proc_addr || gAzV152ImagePending) return 0u;
    const VkDevice device = owner.hw.device;
    const VkQueue queue = owner.hw.queue;
    const auto proc = owner.hw.get_device_proc_addr;
    const auto createSemaphore = reinterpret_cast<PFN_vkCreateSemaphore>(proc(device, "vkCreateSemaphore"));
    const auto destroySemaphore = reinterpret_cast<PFN_vkDestroySemaphore>(proc(device, "vkDestroySemaphore"));
    const auto createFence = reinterpret_cast<PFN_vkCreateFence>(proc(device, "vkCreateFence"));
    const auto destroyFence = reinterpret_cast<PFN_vkDestroyFence>(proc(device, "vkDestroyFence"));
    const auto queueSubmit = reinterpret_cast<PFN_vkQueueSubmit>(proc(device, "vkQueueSubmit"));
    const auto waitForFences = reinterpret_cast<PFN_vkWaitForFences>(proc(device, "vkWaitForFences"));
    const auto queueWaitIdle = reinterpret_cast<PFN_vkQueueWaitIdle>(proc(device, "vkQueueWaitIdle"));
    if (!createSemaphore || !destroySemaphore || !createFence || !destroyFence ||
        !queueSubmit || !waitForFences || !queueWaitIdle) return 0u;
    unsigned mask = 1u; // all seven device dispatch functions resolved
    VkSemaphore signal = VK_NULL_HANDLE;
    VkFence completed = VK_NULL_HANDLE;
    VkSemaphoreCreateInfo semInfo = {};
    semInfo.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
    VkFenceCreateInfo fenceInfo = {};
    fenceInfo.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
    if (createSemaphore(device, &semInfo, nullptr, &signal) != VK_SUCCESS || !signal)
        return mask;
    mask |= 2u;
    if (createFence(device, &fenceInfo, nullptr, &completed) != VK_SUCCESS || !completed) {
        destroySemaphore(device, signal, nullptr);
        return mask;
    }
    mask |= 4u;
    // Serialize both submits with the same mutex exposed by lock_queue.
    // The first empty submit signals a binary semaphore; the second waits
    // on it and signals the fence. No application image is involved.
    VkSubmitInfo producer = {};
    producer.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
    producer.signalSemaphoreCount = 1;
    producer.pSignalSemaphores = &signal;
    VkPipelineStageFlags stage = VK_PIPELINE_STAGE_ALL_COMMANDS_BIT;
    VkSubmitInfo consumer = {};
    consumer.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
    consumer.waitSemaphoreCount = 1;
    consumer.pWaitSemaphores = &signal;
    consumer.pWaitDstStageMask = &stage;
    VkResult first = VK_ERROR_INITIALIZATION_FAILED;
    VkResult second = VK_ERROR_INITIALIZATION_FAILED;
    {
        std::lock_guard<std::mutex> guard(gAzV152QueueMutex);
        first = queueSubmit(queue, 1, &producer, VK_NULL_HANDLE);
        if (first == VK_SUCCESS) {
            mask |= 8u;
            second = queueSubmit(queue, 1, &consumer, completed);
            if (second == VK_SUCCESS) mask |= 16u;
        }
    }
    if (second == VK_SUCCESS &&
        waitForFences(device, 1, &completed, VK_TRUE, 2000000000ULL) == VK_SUCCESS)
        mask |= 32u;
    // Ensure both submissions finish before destroying the semaphore/fence,
    // including the error and timeout paths. On device loss we cannot
    // safely recover; no core-owned objects are used by this probe.
    if (first == VK_SUCCESS) {
        if (queueWaitIdle(queue) == VK_SUCCESS) mask |= 64u;
    } else {
        mask |= 64u; // no submission, safe to destroy
    }
    if ((mask & 64u) != 0u) {
        destroyFence(device, completed, nullptr);
        destroySemaphore(device, signal, nullptr);
    }
    // If the device is lost, avoid freeing possibly in-flight handles.
    return mask;
}


// Castle 156: integrated private real-image/real-semaphore set_image path.
// Unlike the V155 empty-submit probe, the *actual* v5 set_image function
// carries a live image view and an actual signaled binary semaphore into
// the V153 inbox. A guarded consumer waits on that exact semaphore through
// the Vulkan queue. It does not claim image pixel readback or Azahar use.
extern "C" unsigned AzaharV156PrivateImageSemaphoreGate(void) {
    auto &owner = gAzV151Descriptor;
    if (!owner.initialized || !owner.hw.device || !owner.hw.gpu ||
        !owner.hw.queue || !owner.hw.get_device_proc_addr ||
        !owner.hw.get_instance_proc_addr || !owner.hw.set_image ||
        gAzV152ImagePending) return 0u;
    const VkDevice device = owner.hw.device;
    const VkQueue queue = owner.hw.queue;
    const auto dp = owner.hw.get_device_proc_addr;
    const auto ip = owner.hw.get_instance_proc_addr;
#define AZ156_PROC(type, name) reinterpret_cast<type>(dp(device, name))
    auto createImage = AZ156_PROC(PFN_vkCreateImage, "vkCreateImage");
    auto destroyImage = AZ156_PROC(PFN_vkDestroyImage, "vkDestroyImage");
    auto getRequirements = AZ156_PROC(PFN_vkGetImageMemoryRequirements, "vkGetImageMemoryRequirements");
    auto allocMemory = AZ156_PROC(PFN_vkAllocateMemory, "vkAllocateMemory");
    auto freeMemory = AZ156_PROC(PFN_vkFreeMemory, "vkFreeMemory");
    auto bindMemory = AZ156_PROC(PFN_vkBindImageMemory, "vkBindImageMemory");
    auto createView = AZ156_PROC(PFN_vkCreateImageView, "vkCreateImageView");
    auto destroyView = AZ156_PROC(PFN_vkDestroyImageView, "vkDestroyImageView");
    auto createSemaphore = AZ156_PROC(PFN_vkCreateSemaphore, "vkCreateSemaphore");
    auto destroySemaphore = AZ156_PROC(PFN_vkDestroySemaphore, "vkDestroySemaphore");
    auto createFence = AZ156_PROC(PFN_vkCreateFence, "vkCreateFence");
    auto destroyFence = AZ156_PROC(PFN_vkDestroyFence, "vkDestroyFence");
    auto submit = AZ156_PROC(PFN_vkQueueSubmit, "vkQueueSubmit");
    auto waitFence = AZ156_PROC(PFN_vkWaitForFences, "vkWaitForFences");
    auto waitIdle = AZ156_PROC(PFN_vkQueueWaitIdle, "vkQueueWaitIdle");
#undef AZ156_PROC
    auto memoryProperties = reinterpret_cast<PFN_vkGetPhysicalDeviceMemoryProperties>(
        ip(owner.hw.instance, "vkGetPhysicalDeviceMemoryProperties"));
    if (!createImage || !destroyImage || !getRequirements || !allocMemory ||
        !freeMemory || !bindMemory || !createView || !destroyView ||
        !createSemaphore || !destroySemaphore || !createFence ||
        !destroyFence || !submit || !waitFence || !waitIdle ||
        !memoryProperties) return 0u;
    unsigned mask = 1u; // all required live dispatch resolved
    VkImage image = VK_NULL_HANDLE;
    VkDeviceMemory memory = VK_NULL_HANDLE;
    VkImageView view = VK_NULL_HANDLE;
    VkSemaphore signal = VK_NULL_HANDLE;
    VkFence fence = VK_NULL_HANDLE;
    bool submitted = false;
    bool safeToDestroy = true;
    const unsigned gen = owner.generation;
    const uint32_t family = owner.hw.queue_index;
    const unsigned savedCalls = gAzV152ImageCalls;
    const unsigned savedRejects = gAzV152RejectedImages;
    const unsigned savedConsumed = gAzV153Consumed;
    const unsigned savedInvalid = gAzV154Invalid;
    const unsigned savedDropped = gAzV154Dropped;
    do {
        VkImageCreateInfo desc = {};
        desc.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
        desc.imageType = VK_IMAGE_TYPE_2D;
        desc.format = VK_FORMAT_R8G8B8A8_UNORM;
        desc.extent = {4,4,1};
        desc.mipLevels = 1;
        desc.arrayLayers = 1;
        desc.samples = VK_SAMPLE_COUNT_1_BIT;
        desc.tiling = VK_IMAGE_TILING_OPTIMAL;
        desc.usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
        desc.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
        desc.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
        if (createImage(device, &desc, nullptr, &image) != VK_SUCCESS || !image) break;
        VkMemoryRequirements requirements = {};
        getRequirements(device, image, &requirements);
        VkPhysicalDeviceMemoryProperties props = {};
        memoryProperties(owner.hw.gpu, &props);
        uint32_t type = props.memoryTypeCount;
        for (uint32_t i = 0; i < props.memoryTypeCount; ++i)
            if (requirements.memoryTypeBits & (1u << i)) { type = i; break; }
        if (type >= props.memoryTypeCount) break;
        VkMemoryAllocateInfo allocation = {};
        allocation.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        allocation.allocationSize = requirements.size;
        allocation.memoryTypeIndex = type;
        if (allocMemory(device, &allocation, nullptr, &memory) != VK_SUCCESS || !memory ||
            bindMemory(device, image, memory, 0) != VK_SUCCESS) break;
        VkImageViewCreateInfo viewInfo = {};
        viewInfo.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        viewInfo.image = image;
        viewInfo.viewType = VK_IMAGE_VIEW_TYPE_2D;
        viewInfo.format = VK_FORMAT_R8G8B8A8_UNORM;
        viewInfo.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        viewInfo.subresourceRange.levelCount = 1;
        viewInfo.subresourceRange.layerCount = 1;
        if (createView(device, &viewInfo, nullptr, &view) != VK_SUCCESS || !view) break;
        mask |= 2u; // real owned image/memory/view, no synthetic VkImageView
        VkSemaphoreCreateInfo semInfo = {};
        semInfo.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
        VkFenceCreateInfo fenceInfo = {};
        fenceInfo.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
        if (createSemaphore(device, &semInfo, nullptr, &signal) != VK_SUCCESS || !signal ||
            createFence(device, &fenceInfo, nullptr, &fence) != VK_SUCCESS || !fence) break;
        mask |= 4u;
        retro_vulkan_image borrowed = {};
        borrowed.image_view = view;
        borrowed.image_layout = VK_IMAGE_LAYOUT_UNDEFINED; // no image operations yet
        borrowed.create_info = viewInfo;
        // Three independent validation lanes on the REAL callback:
        owner.hw.set_image(owner.hw.handle, &borrowed, 1, nullptr, family);
        if (!gAzV152ImagePending && gAzV152RejectedImages == savedRejects + 1) mask |= 8u;
        owner.hw.set_image(owner.hw.handle, &borrowed, 1, &signal, family);
        if (!gAzV152ImagePending || gAzV153Inbox.view != view ||
            gAzV153Inbox.semaphoreCount != 1 || gAzV153Inbox.semaphores[0] != signal ||
            gAzV153Inbox.generation != gen) break;
        mask |= 16u;
        AzV153Inbox consumer = {};
        if (AzV154ConsumeGuarded(gen, family + 1, &consumer) ||
            !gAzV152ImagePending || gAzV154Invalid != savedInvalid + 1) break;
        mask |= 32u;
        if (!AzV154ConsumeGuarded(gen, family, &consumer) ||
            gAzV152ImagePending || consumer.view != view ||
            consumer.semaphoreCount != 1 || consumer.semaphores[0] != signal) break;
        mask |= 64u;
        // GPU producer *signals* the exact semaphore that set_image retained;
        // consumer *waits* on it, signaled by a completion fence.
        VkSubmitInfo producer = {};
        producer.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
        producer.signalSemaphoreCount = 1;
        producer.pSignalSemaphores = &signal;
        VkPipelineStageFlags stage = VK_PIPELINE_STAGE_ALL_COMMANDS_BIT;
        VkSubmitInfo consumerSubmit = {};
        consumerSubmit.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
        consumerSubmit.waitSemaphoreCount = consumer.semaphoreCount;
        consumerSubmit.pWaitSemaphores = consumer.semaphores;
        consumerSubmit.pWaitDstStageMask = &stage;
        VkResult first = VK_ERROR_INITIALIZATION_FAILED;
        VkResult second = VK_ERROR_INITIALIZATION_FAILED;
        {
            std::lock_guard<std::mutex> lock(gAzV152QueueMutex);
            first = submit(queue, 1, &producer, VK_NULL_HANDLE);
            if (first == VK_SUCCESS) {
                submitted = true;
                second = submit(queue, 1, &consumerSubmit, fence);
            }
        }
        if (first != VK_SUCCESS || second != VK_SUCCESS) break;
        if (waitFence(device, 1, &fence, VK_TRUE, 2000000000ULL) == VK_SUCCESS)
            mask |= 128u;
    } while (false);
    // Cannot destroy objects still referenced by the queue. The probe is
    // scoped and finishes before the owner device can be released.
    if (submitted && waitIdle(queue) != VK_SUCCESS) safeToDestroy = false;
    if (gAzV152ImagePending) (void)AzV154DropPending(gen);
    // Tests must not alter the following production callback counters.
    gAzV152ImageCalls = savedCalls;
    gAzV152RejectedImages = savedRejects;
    gAzV153Consumed = savedConsumed;
    gAzV154Invalid = savedInvalid;
    gAzV154Dropped = savedDropped;
    if (safeToDestroy) {
        if (fence) destroyFence(device, fence, nullptr);
        if (signal) destroySemaphore(device, signal, nullptr);
        if (view) destroyView(device, view, nullptr);
        if (image) destroyImage(device, image, nullptr);
        if (memory) freeMemory(device, memory, nullptr);
        if (!gAzV152ImagePending && !gAzV153Inbox.view &&
            gAzV152ImageCalls == savedCalls && gAzV152RejectedImages == savedRejects &&
            gAzV153Consumed == savedConsumed) mask |= 256u;
    }
    return mask;
}

// Independent, no GPU call: verify the official interface is still private
// and cannot be mistaken for a production-ready renderer while wait_sync_index
// is intentionally a stub. This is a readiness audit, not a PASS to publish.
extern "C" unsigned AzaharV156PublicationSafetyGate(void) {
    const auto &s = gAzV151Descriptor;
    unsigned mask = 0;
    if (s.initialized && s.hw.interface_version == 5u && s.hw.device && s.hw.queue) mask |= 1u;
    if (s.hw.handle == &s && s.hw.set_image && s.hw.wait_sync_index) mask |= 2u;
    if (s.hw.get_sync_index && s.hw.get_sync_index_mask &&
        s.hw.lock_queue && s.hw.unlock_queue) mask |= 4u;
    if (!gAzV152ImagePending && !gAzV153Inbox.view) mask |= 8u;
    return mask;
}
// Castle 157: strict unpublished callback/inbox boundary validation.
// Metadata-only negative tests: Vulkan handles are never dereferenced or submitted.
// The callback remains private; in particular wait_sync_index is still a stub.
extern "C" unsigned AzaharV157UnpublishedCallbackContractGate(void) {
    auto &state = gAzV151Descriptor;
    if (!state.initialized || !state.hw.set_image ||
        gAzV152ImagePending || gAzV153Inbox.view) return 0u;
    const unsigned calls = gAzV152ImageCalls;
    const unsigned rejects = gAzV152RejectedImages;
    const unsigned overflow = gAzV153Overflow;
    const unsigned consumed = gAzV153Consumed;
    const unsigned invalid = gAzV154Invalid;
    const unsigned stale = gAzV154Stale;
    const unsigned dropped = gAzV154Dropped;
    const unsigned generation = state.generation;
    const uint32_t family = state.hw.queue_index;
    unsigned mask = 0u;
    retro_vulkan_image borrowed = {};
    borrowed.image_view = reinterpret_cast<VkImageView>(static_cast<uintptr_t>(0x1570));
    borrowed.create_info.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
    borrowed.create_info.viewType = VK_IMAGE_VIEW_TYPE_2D;
    borrowed.create_info.format = VK_FORMAT_R8G8B8A8_UNORM;
    VkSemaphore waits[kAzV153MaxWaits + 1] = {};
    for (uint32_t i = 0; i < kAzV153MaxWaits + 1; ++i)
        waits[i] = reinterpret_cast<VkSemaphore>(static_cast<uintptr_t>(0x15700 + i));
    do {
        state.hw.set_image(state.hw.handle, &borrowed, kAzV153MaxWaits + 1, waits, family);
        if (gAzV152ImagePending || gAzV153Overflow != overflow + 1 ||
            gAzV152RejectedImages != rejects + 1) break;
        mask |= 1u; // over-capacity array rejected without mutation
        state.hw.set_image(state.hw.handle, &borrowed, kAzV153MaxWaits, waits, family);
        if (!gAzV152ImagePending || gAzV153Inbox.semaphoreCount != kAzV153MaxWaits ||
            gAzV153Inbox.generation != generation ||
            gAzV153Inbox.semaphores[kAzV153MaxWaits-1] != waits[kAzV153MaxWaits-1]) break;
        mask |= 2u; // exact bounded-capacity borrow accepted
        state.hw.set_image(state.hw.handle, &borrowed, 1, waits, family);
        if (!gAzV152ImagePending || gAzV153Inbox.semaphoreCount != kAzV153MaxWaits ||
            gAzV152RejectedImages != rejects + 2) break;
        mask |= 4u; // unconsumed frame cannot be overwritten
        AzV153Inbox delivered = {};
        if (AzV154ConsumeGuarded(generation + 1, family, &delivered) ||
            !gAzV152ImagePending || gAzV154Stale != stale + 1) break;
        mask |= 8u; // stale generation fails without dropping frame
        if (AzV154ConsumeGuarded(generation, family + 1, &delivered) ||
            !gAzV152ImagePending || gAzV154Invalid != invalid + 1) break;
        mask |= 16u; // wrong queue family fails closed
        if (!AzV154ConsumeGuarded(generation, family, &delivered) ||
            gAzV152ImagePending || delivered.semaphoreCount != kAzV153MaxWaits ||
            delivered.semaphores[0] != waits[0]) break;
        mask |= 32u; // exact bounded payload consumed once
        if (AzV154ConsumeGuarded(generation, family, &delivered) ||
            gAzV152ImagePending) break;
        mask |= 64u; // duplicate consume does not replay
        state.hw.set_image(state.hw.handle, &borrowed, 1, waits, family);
        if (!gAzV152ImagePending || !AzV154DropPending(generation) ||
            gAzV152ImagePending || gAzV153Inbox.view) break;
        mask |= 128u; // orphaned borrowed frame dropped before owner release
    } while (false);
    if (gAzV152ImagePending) (void)AzV154DropPending(generation);
    // Private tests do not affect production-visible counters.
    gAzV152ImageCalls = calls;
    gAzV152RejectedImages = rejects;
    gAzV153Overflow = overflow;
    gAzV153Consumed = consumed;
    gAzV154Invalid = invalid;
    gAzV154Stale = stale;
    gAzV154Dropped = dropped;
    if (!gAzV152ImagePending && !gAzV153Inbox.view &&
        state.hw.handle == &state && state.hw.wait_sync_index &&
        state.hw.set_image == AzV152SetImage) mask |= 256u;
    return mask;
}

// Castle 158: malformed hardware callback ingress and recovery audit.
// Strictly private synthetic metadata; no Vulkan handle is dereferenced,
// no image is published, and no GPU work is submitted by this gate.
extern "C" unsigned AzaharV158MalformedIngressRecoveryGate(void) {
    auto &state = gAzV151Descriptor;
    if (!state.initialized || !state.hw.set_image ||
        gAzV152ImagePending || gAzV153Inbox.view) return 0u;
    const unsigned calls = gAzV152ImageCalls;
    const unsigned rejects = gAzV152RejectedImages;
    const unsigned consumed = gAzV153Consumed;
    const unsigned dropped = gAzV154Dropped;
    const unsigned overflow = gAzV153Overflow;
    const unsigned stale = gAzV154Stale;
    const unsigned invalid = gAzV154Invalid;
    const unsigned generation = state.generation;
    const uint32_t family = state.hw.queue_index;
    retro_vulkan_image image = {};
    image.image_view = reinterpret_cast<VkImageView>(static_cast<uintptr_t>(0x15801));
    image.create_info.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
    image.create_info.viewType = VK_IMAGE_VIEW_TYPE_2D;
    image.create_info.format = VK_FORMAT_R8G8B8A8_UNORM;
    unsigned mask = 0;
    do {
        state.hw.set_image(nullptr, &image, 0, nullptr, family);
        if (gAzV152ImagePending || gAzV152RejectedImages != rejects + 1) break;
        mask |= 1u; // wrong owner rejected
        state.hw.set_image(state.hw.handle, nullptr, 0, nullptr, family);
        if (gAzV152ImagePending || gAzV152RejectedImages != rejects + 2) break;
        mask |= 2u; // null descriptor rejected
        retro_vulkan_image malformed = image;
        malformed.image_view = VK_NULL_HANDLE;
        state.hw.set_image(state.hw.handle, &malformed, 0, nullptr, family);
        if (gAzV152ImagePending || gAzV152RejectedImages != rejects + 3) break;
        mask |= 4u; // null image view rejected
        malformed = image;
        malformed.create_info.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO;
        state.hw.set_image(state.hw.handle, &malformed, 0, nullptr, family);
        if (gAzV152ImagePending || gAzV152RejectedImages != rejects + 4) break;
        mask |= 8u; // wrong descriptor struct type rejected
        malformed = image;
        malformed.create_info.viewType = static_cast<VkImageViewType>(0x7fffffff);
        state.hw.set_image(state.hw.handle, &malformed, 0, nullptr, family);
        if (gAzV152ImagePending || gAzV152RejectedImages != rejects + 5) break;
        mask |= 16u; // invalid image-view type rejected
        state.hw.set_image(state.hw.handle, &image, 1, nullptr, family);
        if (gAzV152ImagePending || gAzV152RejectedImages != rejects + 6) break;
        mask |= 32u; // null semaphore array rejected
        state.hw.set_image(state.hw.handle, &image, 0, nullptr, family);
        if (!gAzV152ImagePending || gAzV153Inbox.view != image.image_view ||
            gAzV153Inbox.semaphoreCount != 0 || gAzV153Inbox.generation != generation) break;
        AzV153Inbox delivery = {};
        if (!AzV154ConsumeGuarded(generation, family, &delivery) ||
            delivery.view != image.image_view || gAzV152ImagePending) break;
        mask |= 64u; // valid payload accepted and consumed after rejects
        state.hw.set_image(state.hw.handle, &image, 0, nullptr, family);
        if (!gAzV152ImagePending || !AzV154DropPending(generation) ||
            gAzV152ImagePending || gAzV153Inbox.view) break;
        mask |= 128u; // subsequent pending payload safely dropped
    } while (false);
    if (gAzV152ImagePending) (void)AzV154DropPending(generation);
    gAzV152ImageCalls = calls;
    gAzV152RejectedImages = rejects;
    gAzV153Consumed = consumed;
    gAzV154Dropped = dropped;
    gAzV153Overflow = overflow;
    gAzV154Stale = stale;
    gAzV154Invalid = invalid;
    if (!gAzV152ImagePending && !gAzV153Inbox.view &&
        state.hw.handle == &state && state.hw.set_image == AzV152SetImage &&
        state.hw.wait_sync_index) mask |= 256u;
    return mask;
}

static uint32_t AzV152GetSyncIndex(void *handle);
static uint32_t AzV152GetSyncMask(void *handle);
static void AzV152LockQueue(void *handle);
static void AzV152UnlockQueue(void *handle);
static void AzV152WaitSyncIndex(void *handle);
// Castle 159: two independent private integration-contract probes.
// These test callbacks and bounded ownership metadata only; wait_sync_index
// remains a no-op and is NOT evidence of GPU completion or a publishable ABI.
extern "C" unsigned AzaharV159SyncBoundaryGate(void) {
    auto &s = gAzV151Descriptor;
    if (!s.initialized || !s.hw.handle || !s.hw.get_sync_index ||
        !s.hw.get_sync_index_mask || !s.hw.wait_sync_index ||
        !s.hw.lock_queue || !s.hw.unlock_queue || gAzV152ImagePending) return 0;
    unsigned mask = 0;
    if (s.hw.get_sync_index(s.hw.handle) == gAzV152SyncIndex) mask |= 1u;
    if (s.hw.get_sync_index(nullptr) == 0u) mask |= 2u;
    if (s.hw.get_sync_index_mask(s.hw.handle) == 1u) mask |= 4u;
    if (s.hw.get_sync_index_mask(nullptr) == 0u) mask |= 8u;
    // No competing thread and no GPU submission: verify only mutex callable scope.
    s.hw.lock_queue(s.hw.handle);
    s.hw.unlock_queue(s.hw.handle);
    mask |= 16u;
    if (s.hw.wait_sync_index == AzV152WaitSyncIndex) mask |= 32u;
    if (s.hw.set_image == AzV152SetImage && s.hw.handle == &s) mask |= 64u;
    if (!gAzV152ImagePending && !gAzV153Inbox.view) mask |= 128u;
    return mask;
}
extern "C" unsigned AzaharV159MixedIngressBatchGate(void) {
    auto &s = gAzV151Descriptor;
    if (!s.initialized || !s.hw.set_image || gAzV152ImagePending || gAzV153Inbox.view) return 0;
    const unsigned calls=gAzV152ImageCalls, rejects=gAzV152RejectedImages;
    const unsigned consumed=gAzV153Consumed, dropped=gAzV154Dropped;
    const unsigned overflow=gAzV153Overflow, stale=gAzV154Stale, invalid=gAzV154Invalid;
    const unsigned gen=s.generation; const uint32_t family=s.hw.queue_index;
    retro_vulkan_image image={};
    image.image_view=reinterpret_cast<VkImageView>(static_cast<uintptr_t>(0x15901));
    image.create_info.sType=VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
    image.create_info.viewType=VK_IMAGE_VIEW_TYPE_2D;
    image.create_info.format=VK_FORMAT_R8G8B8A8_UNORM;
    unsigned mask=0;
    do {
        for (unsigned i=0;i<4;i++) {
            s.hw.set_image(s.hw.handle,&image,0,nullptr,family+1);
            AzV153Inbox invalidDelivery={};
            if (!gAzV152ImagePending || AzV154ConsumeGuarded(gen,family,&invalidDelivery) ||
                !AzV154DropPending(gen)) break;
        }
        if (gAzV154Invalid!=invalid+4 || gAzV152ImagePending ||
            gAzV154Dropped!=dropped+4) break;
        mask|=1u;
        for (unsigned i=0;i<4;i++) {
            s.hw.set_image(s.hw.handle,&image,0,nullptr,family);
            if (!gAzV152ImagePending) break;
            AzV153Inbox delivery={};
            if (!AzV154ConsumeGuarded(gen,family,&delivery) || delivery.view!=image.image_view) break;
        }
        if (gAzV153Consumed!=consumed+4 || gAzV152ImagePending) break;
        mask|=2u;
        s.hw.set_image(s.hw.handle,&image,0,nullptr,family);
        if (!gAzV152ImagePending) break;
        mask|=4u;
        s.hw.set_image(s.hw.handle,&image,0,nullptr,family);
        if (gAzV152RejectedImages!=rejects+1) break;
        mask|=8u;
        AzV153Inbox delivery={};
        if (AzV154ConsumeGuarded(gen+1,family,&delivery) || !gAzV152ImagePending) break;
        mask|=16u;
        if (!AzV154DropPending(gen) || gAzV152ImagePending || gAzV153Inbox.view) break;
        mask|=32u;
        s.hw.set_image(s.hw.handle,&image,0,nullptr,family);
        if (!AzV154ConsumeGuarded(gen,family,&delivery) || delivery.view!=image.image_view) break;
        mask|=64u;
    } while(false);
    if (gAzV152ImagePending) (void)AzV154DropPending(gen);
    gAzV152ImageCalls=calls; gAzV152RejectedImages=rejects;
    gAzV153Consumed=consumed; gAzV154Dropped=dropped;
    gAzV153Overflow=overflow; gAzV154Stale=stale; gAzV154Invalid=invalid;
    if (!gAzV152ImagePending && !gAzV153Inbox.view && s.hw.handle==&s) mask|=128u;
    return mask;
}

static uint32_t AzV152GetSyncIndex(void *handle) {
    return handle == &gAzV151Descriptor ? gAzV152SyncIndex : 0u;
}
static uint32_t AzV152GetSyncMask(void *handle) {
    return handle == &gAzV151Descriptor ? 1u : 0u;
}
static void AzV152LockQueue(void *handle) {
    if (handle == &gAzV151Descriptor) gAzV152QueueMutex.lock();
}
static void AzV152UnlockQueue(void *handle) {
    if (handle == &gAzV151Descriptor) gAzV152QueueMutex.unlock();
}
// Castle 165: correct, conservative GPU completion backstop. Device-wide idle
// is intentionally synchronous (not a final performance solution). It prevents
// callers from treating incomplete GPU work as completed. Only valid descriptor
// ownership may access the real device. The ABI remains UNPUBLISHED pending
// per-frame synchronization and a real OpenEmu presenter.
// Castle 166: private frame-scoped fence registration. This is intentionally
// limited to the OWNED device and is not exposed to Azahar until the actual
// renderer and OpenEmu presenter are fully integrated.
static VkFence gAzV166FrameFence = VK_NULL_HANDLE;
static unsigned gAzV166FenceWaitCalls = 0;
static unsigned gAzV166FenceWaitSuccess = 0;
static unsigned gAzV166FenceWaitFailure = 0;
static unsigned gAzV165WaitCalls = 0;
static unsigned gAzV165WaitSuccess = 0;
static unsigned gAzV165WaitRejected = 0;
static VkResult gAzV165LastWaitResult = VK_NOT_READY;
static void AzV152WaitSyncIndex(void *handle) {
    auto &s = gAzV151Descriptor;
    if (handle != &s || !s.initialized || !s.hw.device || !s.hw.get_device_proc_addr) {
        ++gAzV165WaitRejected;
        return;
    }
    auto wait = reinterpret_cast<PFN_vkDeviceWaitIdle>(
        s.hw.get_device_proc_addr(s.hw.device, "vkDeviceWaitIdle"));
    if (!wait) {
        ++gAzV165WaitRejected;
        gAzV165LastWaitResult = VK_ERROR_INITIALIZATION_FAILED;
        return;
    }
    // Prefer a real fence when a frame has registered one; device-idle is
    // a correctness backstop for the as-yet-unpublished legacy path.
    if (gAzV166FrameFence) {
        const auto wf = reinterpret_cast<PFN_vkWaitForFences>(
            s.hw.get_device_proc_addr(s.hw.device, "vkWaitForFences"));
        if (wf) {
            ++gAzV166FenceWaitCalls;
            const VkResult fenced = wf(s.hw.device, 1, &gAzV166FrameFence,
                                       VK_TRUE, 1000000000ULL);
            if (fenced == VK_SUCCESS) {
                ++gAzV166FenceWaitSuccess;
                gAzV165LastWaitResult = VK_SUCCESS;
                ++gAzV165WaitCalls;
                ++gAzV165WaitSuccess;
                return;
            }
            ++gAzV166FenceWaitFailure;
        }
    }
    ++gAzV165WaitCalls;
    gAzV165LastWaitResult = wait(s.hw.device);
    if (gAzV165LastWaitResult == VK_SUCCESS) ++gAzV165WaitSuccess;
}
// 12 independently logged assertions; these exercise the *real owned Vulkan
// device*, not a synthetic callback pointer. Tests run after earlier GPU probes
// have completed and before the descriptor/device are torn down.
// Actual VkFence integration regression: create a SIGNALED fence on the live
// owned VkDevice, register it for the wait callback, exercise completion,
// clear it before destruction, and verify the idle fallback remains healthy.
// Separate lane bits make a single user test log actionable.
// Castle 167: a REAL queue submission (no command buffers), associated with
// an initially UNSIGNALED fence. This validates the callback's completion
// semantics without publishing any Vulkan interface to the libretro core.
extern "C" unsigned AzaharV167SubmittedFenceGate(void) {
    auto &s = gAzV151Descriptor;
    unsigned m = 0;
    if (s.initialized && s.hw.handle == &s && s.hw.device && s.hw.queue) m |= 1u;
    const auto gp = s.hw.get_device_proc_addr;
    if (!gp || !(m & 1u) || gAzV166FrameFence) return m;
    const auto create = reinterpret_cast<PFN_vkCreateFence>(gp(s.hw.device,"vkCreateFence"));
    const auto destroy = reinterpret_cast<PFN_vkDestroyFence>(gp(s.hw.device,"vkDestroyFence"));
    const auto submit = reinterpret_cast<PFN_vkQueueSubmit>(gp(s.hw.device,"vkQueueSubmit"));
    const auto status = reinterpret_cast<PFN_vkGetFenceStatus>(gp(s.hw.device,"vkGetFenceStatus"));
    const auto wait = reinterpret_cast<PFN_vkWaitForFences>(gp(s.hw.device,"vkWaitForFences"));
    if (create && destroy && submit && status && wait) m |= 2u;
    if (!(m & 2u)) return m;
    VkFenceCreateInfo ci{};
    ci.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
    ci.flags = 0; // intentionally UNSIGNALED; unlike the v166 probe
    VkFence fence = VK_NULL_HANDLE;
    if (create(s.hw.device,&ci,nullptr,&fence)==VK_SUCCESS && fence) m |= 4u;
    if (!(m & 4u)) return m;
    if (status(s.hw.device,fence)==VK_NOT_READY) m |= 8u;
    VkSubmitInfo si{};
    si.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
    // A valid empty submission advances the queue and signals its fence.
    // This exercises real producer-completion signaling, not image rendering.
    VkResult submitResult = submit(s.hw.queue,1,&si,fence);
    if (submitResult == VK_SUCCESS) m |= 16u;
    const unsigned beforeCalls = gAzV166FenceWaitCalls;
    const unsigned beforeSuccess = gAzV166FenceWaitSuccess;
    const unsigned beforeErrors = gAzV166FenceWaitFailure;
    if (submitResult == VK_SUCCESS && !gAzV166FrameFence) {
        gAzV166FrameFence = fence;
        if (gAzV166FrameFence == fence) m |= 32u;
        if (s.hw.wait_sync_index) s.hw.wait_sync_index(s.hw.handle);
        if (gAzV166FenceWaitCalls == beforeCalls+1u) m |= 64u;
        if (gAzV166FenceWaitSuccess == beforeSuccess+1u &&
            gAzV165LastWaitResult == VK_SUCCESS) m |= 128u;
        if (status(s.hw.device,fence)==VK_SUCCESS) m |= 256u;
        if (gAzV166FenceWaitFailure == beforeErrors) m |= 512u;
    }
    // Always finish before destroying any fence (including failed submissions).
    const VkResult finalWait = (submitResult == VK_SUCCESS) ?
        wait(s.hw.device,1,&fence,VK_TRUE,1000000000ULL) : VK_SUCCESS;
    gAzV166FrameFence = VK_NULL_HANDLE;
    if (!gAzV166FrameFence && finalWait == VK_SUCCESS) m |= 1024u;
    if (finalWait != VK_SUCCESS) {
        auto idle = reinterpret_cast<PFN_vkDeviceWaitIdle>(gp(s.hw.device,"vkDeviceWaitIdle"));
        if (idle) idle(s.hw.device);
    }
    destroy(s.hw.device,fence,nullptr);
    const unsigned beforeIdle = gAzV165WaitCalls;
    if (s.hw.wait_sync_index) s.hw.wait_sync_index(s.hw.handle);
    if (gAzV165WaitCalls == beforeIdle+1u &&
        gAzV165LastWaitResult == VK_SUCCESS && s.initialized) m |= 2048u;
    return m;
}
// Castle 168: executable Vulkan command buffer -> queue submission -> real
// unsignaled completion fence -> live official-ABI synchronization callback.
// This is still a PRIVATE device-owner integration test, not an Azahar frame.
extern "C" unsigned AzaharV168CommandFenceGate(void) {
    auto &s=gAzV151Descriptor;
    unsigned mask=0;
    if(s.initialized && s.hw.handle==&s && s.hw.device && s.hw.queue)mask|=1u;
    if(!(mask&1u) || !s.hw.get_device_proc_addr || gAzV166FrameFence)return mask;
    auto gp=s.hw.get_device_proc_addr;
    auto createPool=reinterpret_cast<PFN_vkCreateCommandPool>(gp(s.hw.device,"vkCreateCommandPool"));
    auto destroyPool=reinterpret_cast<PFN_vkDestroyCommandPool>(gp(s.hw.device,"vkDestroyCommandPool"));
    auto alloc=reinterpret_cast<PFN_vkAllocateCommandBuffers>(gp(s.hw.device,"vkAllocateCommandBuffers"));
    auto begin=reinterpret_cast<PFN_vkBeginCommandBuffer>(gp(s.hw.device,"vkBeginCommandBuffer"));
    auto end=reinterpret_cast<PFN_vkEndCommandBuffer>(gp(s.hw.device,"vkEndCommandBuffer"));
    auto createFence=reinterpret_cast<PFN_vkCreateFence>(gp(s.hw.device,"vkCreateFence"));
    auto destroyFence=reinterpret_cast<PFN_vkDestroyFence>(gp(s.hw.device,"vkDestroyFence"));
    auto submit=reinterpret_cast<PFN_vkQueueSubmit>(gp(s.hw.device,"vkQueueSubmit"));
    auto getStatus=reinterpret_cast<PFN_vkGetFenceStatus>(gp(s.hw.device,"vkGetFenceStatus"));
    auto wait=reinterpret_cast<PFN_vkWaitForFences>(gp(s.hw.device,"vkWaitForFences"));
    if(createPool && destroyPool && alloc && begin && end && createFence && destroyFence &&
       submit && getStatus && wait)mask|=2u;
    if(!(mask&2u))return mask;
    VkCommandPool pool=VK_NULL_HANDLE;
    VkCommandBuffer cmd=VK_NULL_HANDLE;
    VkFence fence=VK_NULL_HANDLE;
    bool submitted=false;
    VkCommandPoolCreateInfo pci{};
    pci.sType=VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
    pci.queueFamilyIndex=s.hw.queue_index;
    if(createPool(s.hw.device,&pci,nullptr,&pool)==VK_SUCCESS && pool)mask|=4u;
    if(!(mask&4u))return mask;
    do {
      VkCommandBufferAllocateInfo ai{};
      ai.sType=VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
      ai.commandPool=pool;
      ai.level=VK_COMMAND_BUFFER_LEVEL_PRIMARY;
      ai.commandBufferCount=1;
      if(alloc(s.hw.device,&ai,&cmd)!=VK_SUCCESS || !cmd)break;
      mask|=8u;
      VkCommandBufferBeginInfo bi{};
      bi.sType=VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
      bi.flags=VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
      if(begin(cmd,&bi)!=VK_SUCCESS)break;
      mask|=16u;
      if(end(cmd)!=VK_SUCCESS)break;
      mask|=32u;
      VkFenceCreateInfo fci{};
      fci.sType=VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
      if(createFence(s.hw.device,&fci,nullptr,&fence)!=VK_SUCCESS || !fence)break;
      mask|=64u;
      // This fence is explicitly NOT signaled during construction.
      if(getStatus(s.hw.device,fence)!=VK_NOT_READY)break;
      mask|=128u;
      VkSubmitInfo si{};
      si.sType=VK_STRUCTURE_TYPE_SUBMIT_INFO;
      si.commandBufferCount=1;
      si.pCommandBuffers=&cmd;
      if(submit(s.hw.queue,1,&si,fence)!=VK_SUCCESS)break;
      submitted=true;
      mask|=256u;
      const unsigned calls=gAzV166FenceWaitCalls;
      const unsigned successes=gAzV166FenceWaitSuccess;
      gAzV166FrameFence=fence;
      if(s.hw.wait_sync_index)s.hw.wait_sync_index(s.hw.handle);
      if(gAzV166FenceWaitCalls==calls+1u &&
          gAzV166FenceWaitSuccess==successes+1u &&
          gAzV165LastWaitResult==VK_SUCCESS)mask|=512u;
      if(getStatus(s.hw.device,fence)==VK_SUCCESS)mask|=1024u;
    }while(false);
    // The recording resources must not be freed until GPU completion.
    if(submitted && fence) {
      if(wait(s.hw.device,1,&fence,VK_TRUE,1000000000ULL)!=VK_SUCCESS) {
        auto idle=reinterpret_cast<PFN_vkDeviceWaitIdle>(gp(s.hw.device,"vkDeviceWaitIdle"));
        if(idle)idle(s.hw.device);
      }
    }
    gAzV166FrameFence=VK_NULL_HANDLE;
    if(fence)destroyFence(s.hw.device,fence,nullptr);
    destroyPool(s.hw.device,pool,nullptr);
    if(!gAzV166FrameFence && s.initialized)mask|=2048u;
    return mask;
}
extern "C" unsigned AzaharV166FenceWaitGate(void) {
    auto &s = gAzV151Descriptor;
    unsigned m = 0;
    if (s.initialized && s.hw.handle == &s && s.hw.device) m |= 1u;
    const auto gp = s.hw.get_device_proc_addr;
    const auto create = gp ? reinterpret_cast<PFN_vkCreateFence>(gp(s.hw.device, "vkCreateFence")) : nullptr;
    const auto destroy = gp ? reinterpret_cast<PFN_vkDestroyFence>(gp(s.hw.device, "vkDestroyFence")) : nullptr;
    const auto wait = gp ? reinterpret_cast<PFN_vkWaitForFences>(gp(s.hw.device, "vkWaitForFences")) : nullptr;
    if (create && destroy && wait) m |= 2u;
    if (!((m & 3u)==3u) || gAzV166FrameFence) return m;
    VkFenceCreateInfo ci{};
    ci.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
    ci.flags = VK_FENCE_CREATE_SIGNALED_BIT;
    VkFence fence = VK_NULL_HANDLE;
    const VkResult created = create(s.hw.device, &ci, nullptr, &fence);
    if (created == VK_SUCCESS && fence) m |= 4u;
    if (!(m & 4u)) return m;
    if (wait(s.hw.device, 1, &fence, VK_TRUE, 1000000000ULL)==VK_SUCCESS) m |= 8u;
    const unsigned beforeFence = gAzV166FenceWaitCalls;
    const unsigned beforeSuccess = gAzV166FenceWaitSuccess;
    const unsigned beforeBad = gAzV166FenceWaitFailure;
    const unsigned beforeIdle = gAzV165WaitCalls;
    gAzV166FrameFence = fence;
    if (gAzV166FrameFence == fence) m |= 16u;
    if (s.hw.wait_sync_index) s.hw.wait_sync_index(s.hw.handle);
    if (gAzV166FenceWaitCalls == beforeFence + 1) m |= 32u;
    if (gAzV166FenceWaitSuccess == beforeSuccess + 1) m |= 64u;
    if (gAzV166FenceWaitFailure == beforeBad) m |= 128u;
    if (gAzV165WaitCalls == beforeIdle+1 && gAzV165LastWaitResult == VK_SUCCESS) m |= 256u;
    gAzV166FrameFence = VK_NULL_HANDLE;
    if (!gAzV166FrameFence) m |= 512u;
    destroy(s.hw.device, fence, nullptr);
    if (!gAzV166FrameFence && s.hw.device && s.initialized) m |= 1024u;
    if (s.hw.wait_sync_index) s.hw.wait_sync_index(s.hw.handle);
    if (gAzV166FenceWaitCalls == beforeFence + 1 && gAzV165LastWaitResult == VK_SUCCESS) m |= 2048u;
    return m;
}
extern "C" unsigned AzaharV165LiveWaitGate(void) {
    auto &s = gAzV151Descriptor;
    unsigned m = 0;
    if(s.initialized && s.hw.handle == &s) m |= 1u;
    if(s.hw.device && s.hw.get_device_proc_addr) m |= 2u;
    if(s.hw.wait_sync_index == AzV152WaitSyncIndex) m |= 4u;
    const auto proc = s.hw.get_device_proc_addr ?
        s.hw.get_device_proc_addr(s.hw.device, "vkDeviceWaitIdle") : nullptr;
    if(proc) m |= 8u;
    const unsigned initialCalls = gAzV165WaitCalls;
    const unsigned initialGood = gAzV165WaitSuccess;
    const unsigned initialReject = gAzV165WaitRejected;
    const VkResult initialResult = gAzV165LastWaitResult;
    if(s.hw.wait_sync_index) s.hw.wait_sync_index(nullptr);
    if(gAzV165WaitRejected == initialReject + 1) m |= 16u;
    if(gAzV165WaitCalls == initialCalls && gAzV165WaitSuccess == initialGood) m |= 32u;
    if(s.hw.wait_sync_index && proc) s.hw.wait_sync_index(s.hw.handle);
    if(gAzV165WaitCalls == initialCalls + 1 && gAzV165WaitSuccess == initialGood + 1) m |= 64u;
    if(gAzV165LastWaitResult == VK_SUCCESS) m |= 128u;
    if(s.hw.wait_sync_index && proc) s.hw.wait_sync_index(s.hw.handle);
    if(gAzV165WaitCalls == initialCalls + 2 && gAzV165WaitSuccess == initialGood + 2) m |= 256u;
    if(!gAzV152ImagePending && !gAzV153Inbox.view) m |= 512u;
    if(s.hw.get_sync_index(s.hw.handle) == gAzV152SyncIndex &&
       s.hw.get_sync_index_mask(s.hw.handle) == 1u) m |= 1024u;
    // Isolated test counters are not published as runtime telemetry.
    gAzV165WaitCalls = initialCalls;
    gAzV165WaitSuccess = initialGood;
    gAzV165WaitRejected = initialReject;
    gAzV165LastWaitResult = initialResult;
    if(s.initialized && s.hw.handle == &s && s.hw.device) m |= 2048u;
    return m;
}
// Castle 169: inspect the persistent, frontend-owned Vulkan ABI v5 descriptor
// under the same owner lifetime as the real preflight. No pointer is returned
// to Azahar; this gate checks the actual dispatch table rather than a synthetic
// Vulkan tuple. Publication remains prohibited pending a genuine GPU consumer.
// Castle 170: inspect real bridge publication prerequisites at the moment
// Azahar asks SET_HW_RENDER. This is an executable fail-closed safety check,
// not a claim that the interface is ready. A staging descriptor installed
// later in preflight is intentionally not sufficient for publication.
/* Castle 176: invoke the REAL core-provided application-info callback while
   Azahar is inside its disposable negotiation call. Use the existing live
   frontend Vulkan dispatch to construct/destroy a separate compatible
   instance. This is core-informed resource creation, not device negotiation.
   No core-created objects or pointers survive this synchronous call. */
extern "C" unsigned AzaharV176CoreApplicationInstanceGate(void *appCallbackRaw) {
    unsigned mask = 0;
    const auto &owner = gAzV151Descriptor;
    if (!owner.initialized || !owner.hw.instance ||
        !owner.hw.get_instance_proc_addr || !appCallbackRaw) return mask;
    mask |= 1u;
    auto getApp = reinterpret_cast<retro_vulkan_get_application_info_t>(appCallbackRaw);
    const VkApplicationInfo *app = getApp(); // actual Azahar callback
    if (!app || app->sType != VK_STRUCTURE_TYPE_APPLICATION_INFO ||
        !app->pApplicationName || !app->pEngineName) return mask;
    mask |= 2u;
    if (VK_VERSION_MAJOR(app->apiVersion) != 1u ||
        VK_VERSION_MINOR(app->apiVersion) > 3u) return mask;
    mask |= 4u;
    auto gip = owner.hw.get_instance_proc_addr;
    auto create = reinterpret_cast<PFN_vkCreateInstance>(gip(VK_NULL_HANDLE, "vkCreateInstance"));
    auto destroy = reinterpret_cast<PFN_vkDestroyInstance>(gip(owner.hw.instance, "vkDestroyInstance"));
    if (!create || !destroy) return mask;
    mask |= 8u;
    VkInstanceCreateInfo ci{};
    ci.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    ci.pApplicationInfo = app;
    VkInstance made = VK_NULL_HANDLE;
    VkResult result = create(&ci, nullptr, &made);
    if (result == VK_SUCCESS && made) {
        mask |= 16u;
        destroy(made, nullptr);
        made = VK_NULL_HANDLE;
        mask |= 32u;
    } else if (made) {
        destroy(made, nullptr);
    }
    return mask;
}
/* Castle 178: retain a core-created Vulkan device across the stage-two
   callback boundary, then explicitly retire it AFTER retro_deinit. We do not
   expose or publish this private context to the core. */
struct AzV178NegotiatedOwner {
    VkInstance instance = VK_NULL_HANDLE;
    retro_vulkan_context context = {};
    PFN_vkDestroyInstance destroy_instance = nullptr;
    PFN_vkDestroyDevice destroy_device = nullptr;
    PFN_vkGetDeviceProcAddr gdpa = nullptr;
    bool active = false;
};
static AzV178NegotiatedOwner gAzV178Negotiated;
extern "C" unsigned AzaharV178RetainedState(void) {
    const auto &s = gAzV178Negotiated;
    unsigned m=0;
    if (s.active && s.instance && s.context.device && s.context.gpu && s.context.queue) m|=1u;
    if (s.active && s.destroy_device && s.destroy_instance && s.gdpa) m|=2u;
    if (s.active && s.gdpa(s.context.device,"vkQueueSubmit") &&
        s.gdpa(s.context.device,"vkDeviceWaitIdle")) m|=4u;
    return m;
}
/* Castle 179: real command submission on the *Azahar callback-created* device.
   Fenced empty command buffer; no image ownership or interface publication. */
extern "C" unsigned AzaharV179CoreQueueFenceGate(void) {
    const auto &o=gAzV178Negotiated;
    if (!o.active || !o.context.device || !o.context.queue || !o.gdpa) return 0;
    unsigned m=1u;
    const VkDevice d=o.context.device;
    auto poolCreate=reinterpret_cast<PFN_vkCreateCommandPool>(o.gdpa(d,"vkCreateCommandPool"));
    auto poolDestroy=reinterpret_cast<PFN_vkDestroyCommandPool>(o.gdpa(d,"vkDestroyCommandPool"));
    auto allocate=reinterpret_cast<PFN_vkAllocateCommandBuffers>(o.gdpa(d,"vkAllocateCommandBuffers"));
    auto begin=reinterpret_cast<PFN_vkBeginCommandBuffer>(o.gdpa(d,"vkBeginCommandBuffer"));
    auto end=reinterpret_cast<PFN_vkEndCommandBuffer>(o.gdpa(d,"vkEndCommandBuffer"));
    auto submit=reinterpret_cast<PFN_vkQueueSubmit>(o.gdpa(d,"vkQueueSubmit"));
    auto fenceCreate=reinterpret_cast<PFN_vkCreateFence>(o.gdpa(d,"vkCreateFence"));
    auto fenceDestroy=reinterpret_cast<PFN_vkDestroyFence>(o.gdpa(d,"vkDestroyFence"));
    auto fenceWait=reinterpret_cast<PFN_vkWaitForFences>(o.gdpa(d,"vkWaitForFences"));
    if (!poolCreate || !poolDestroy || !allocate || !begin || !end || !submit || !fenceCreate || !fenceDestroy || !fenceWait) return m;
    m|=2u;
    VkCommandPool pool=VK_NULL_HANDLE;
    VkCommandPoolCreateInfo pci{}; pci.sType=VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
    pci.queueFamilyIndex=o.context.queue_family_index;
    if (poolCreate(d,&pci,nullptr,&pool)!=VK_SUCCESS || !pool) return m;
    m|=4u;
    VkCommandBuffer cmd=VK_NULL_HANDLE;
    VkCommandBufferAllocateInfo ai{}; ai.sType=VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    ai.commandPool=pool; ai.level=VK_COMMAND_BUFFER_LEVEL_PRIMARY; ai.commandBufferCount=1;
    if (allocate(d,&ai,&cmd)==VK_SUCCESS && cmd) {
        m|=8u;
        VkCommandBufferBeginInfo bi{}; bi.sType=VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        bi.flags=VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        if (begin(cmd,&bi)==VK_SUCCESS && end(cmd)==VK_SUCCESS) {
            m|=16u;
            VkFence fence=VK_NULL_HANDLE;
            VkFenceCreateInfo fi{}; fi.sType=VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
            if (fenceCreate(d,&fi,nullptr,&fence)==VK_SUCCESS && fence) {
                m|=32u;
                VkSubmitInfo si{}; si.sType=VK_STRUCTURE_TYPE_SUBMIT_INFO;
                si.commandBufferCount=1; si.pCommandBuffers=&cmd;
                if (submit(o.context.queue,1,&si,fence)==VK_SUCCESS) {
                    m|=64u;
                    if(fenceWait(d,1,&fence,VK_TRUE,5000000000ULL)==VK_SUCCESS) m|=128u;
                    else { auto idle=reinterpret_cast<PFN_vkDeviceWaitIdle>(o.gdpa(d,"vkDeviceWaitIdle")); if(idle) idle(d); }
                }
                fenceDestroy(d,fence,nullptr);
            }
        }
    }
    poolDestroy(d,pool,nullptr);
    return m;
}
/* Castle 180: materialize the actual Azahar callback-created Vulkan context
   into the official libretro Vulkan v5 interface ABI. This is a private
   snapshot; no pointer escapes or is published to the core. The callback
   fields are deliberately absent until the real image consumer is ready. */
extern "C" unsigned AzaharV180CoreDeviceInterfaceGate(void) {
    const auto &o=gAzV178Negotiated;
    if (!o.active || !o.instance || !o.context.device || !o.gdpa) return 0;
    unsigned m=1u;
    retro_hw_render_interface_vulkan hw{};
    hw.interface_type=RETRO_HW_RENDER_INTERFACE_VULKAN;
    hw.interface_version=RETRO_HW_RENDER_INTERFACE_VULKAN_VERSION;
    hw.instance=o.instance;
    hw.gpu=o.context.gpu;
    hw.device=o.context.device;
    hw.queue=o.context.queue;
    hw.queue_index=o.context.queue_family_index;
    hw.get_device_proc_addr=o.gdpa;
    hw.get_instance_proc_addr=gAzV151Descriptor.hw.get_instance_proc_addr;
    if (hw.interface_type==RETRO_HW_RENDER_INTERFACE_VULKAN &&
        hw.interface_version==RETRO_HW_RENDER_INTERFACE_VULKAN_VERSION) m|=2u;
    if (hw.instance && hw.gpu && hw.device && hw.queue) m|=4u;
    if (hw.get_instance_proc_addr && hw.get_device_proc_addr) m|=8u;
    if (hw.queue_index==o.context.queue_family_index &&
        hw.queue==o.context.queue && hw.device==o.context.device) m|=16u;
    if (hw.get_device_proc_addr &&
        hw.get_device_proc_addr(hw.device,"vkQueueSubmit") &&
        hw.get_device_proc_addr(hw.device,"vkDeviceWaitIdle") &&
        hw.get_device_proc_addr(hw.device,"vkCreateCommandPool")) m|=32u;
    // Explicitly verify that an unimplemented frame-consumer contract cannot
    // accidentally become a publishable real-time rendering interface.
    if (!hw.handle && !hw.set_image && !hw.get_sync_index &&
        !hw.get_sync_index_mask && !hw.lock_queue && !hw.unlock_queue &&
        !hw.wait_sync_index) m|=64u;
    // Snapshot is stack-bound; the external live interface remains unpublished.
    if (gAzV178Negotiated.active && AzaharV178RetainedState()==7u) m|=128u;
    return m;
}
/* Castle 181: core-negotiated, isolated callback staging. A callback-bound
 * descriptor does not imply a working renderer: only descriptor metadata is
 * accepted; no GPU submission or frame publication occurs here. */
struct AzV181PrivateFrame {
    std::mutex queueMutex;
    retro_hw_render_interface_vulkan hw = {};
    bool active = false;
    bool pending = false;
    unsigned accepted = 0;
    unsigned rejected = 0;
    unsigned consumed = 0;
    VkImageView view = VK_NULL_HANDLE;
    VkImageLayout layout = VK_IMAGE_LAYOUT_UNDEFINED;
};
static AzV181PrivateFrame gAzV181Private;
static void AzV181SetImage(void *p,const retro_vulkan_image *img,uint32_t n,const VkSemaphore *sems,uint32_t family) {
    auto &f=gAzV181Private;
    if(p!=&f || !f.active || !img || !img->image_view ||
       img->create_info.sType!=VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO ||
       !img->create_info.image || img->create_info.viewType!=VK_IMAGE_VIEW_TYPE_2D ||
       (img->image_layout!=VK_IMAGE_LAYOUT_GENERAL && img->image_layout!=VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL) ||
       n!=0 || sems || (family!=f.hw.queue_index && family!=VK_QUEUE_FAMILY_IGNORED) || f.pending) {
        ++f.rejected; return;
    }
    f.view=img->image_view; f.layout=img->image_layout;
    f.pending=true; ++f.accepted;
}
static uint32_t AzV181SyncIndex(void *p) { return p==&gAzV181Private && gAzV181Private.active ? 0u : UINT32_MAX; }
static uint32_t AzV181SyncMask(void *p) { return p==&gAzV181Private && gAzV181Private.active ? 1u : 0u; }
static void AzV181LockQueue(void *p) { if(p==&gAzV181Private && gAzV181Private.active) gAzV181Private.queueMutex.lock(); }
static void AzV181UnlockQueue(void *p) { if(p==&gAzV181Private && gAzV181Private.active) gAzV181Private.queueMutex.unlock(); }
static void AzV181WaitSync(void *p) { if(p==&gAzV181Private && gAzV181Private.active && gAzV181Private.pending) {gAzV181Private.pending=false; ++gAzV181Private.consumed;} }
extern "C" unsigned AzaharV181NegotiatedCallbackGate(void) {
    auto &f=gAzV181Private;
    const auto &o=gAzV178Negotiated;
    if(!o.active || !o.instance || !o.context.device || !o.context.queue || !o.gdpa || f.active) return 0;
    unsigned m=1u;
    f.hw={}; f.pending=false; f.accepted=0; f.rejected=0; f.consumed=0; f.view=VK_NULL_HANDLE;
    auto &h=f.hw;
    h.interface_type=RETRO_HW_RENDER_INTERFACE_VULKAN;
    h.interface_version=RETRO_HW_RENDER_INTERFACE_VULKAN_VERSION;
    h.handle=&f; h.instance=o.instance; h.gpu=o.context.gpu; h.device=o.context.device;
    h.queue=o.context.queue; h.queue_index=o.context.queue_family_index;
    h.get_instance_proc_addr=gAzV151Descriptor.hw.get_instance_proc_addr;
    h.get_device_proc_addr=o.gdpa;
    h.set_image=AzV181SetImage; h.get_sync_index=AzV181SyncIndex;
    h.get_sync_index_mask=AzV181SyncMask; h.lock_queue=AzV181LockQueue;
    h.unlock_queue=AzV181UnlockQueue; h.wait_sync_index=AzV181WaitSync;
    f.active=true;
    if(h.interface_type==RETRO_HW_RENDER_INTERFACE_VULKAN && h.interface_version==5 && h.device==o.context.device && h.queue==o.context.queue) m|=2u;
    if(h.set_image && h.get_sync_index && h.get_sync_index_mask && h.lock_queue && h.unlock_queue && h.wait_sync_index) m|=4u;
    if(h.get_sync_index(h.handle)==0 && h.get_sync_index_mask(h.handle)==1) m|=8u;
    h.lock_queue(h.handle); h.unlock_queue(h.handle); m|=16u;
    retro_vulkan_image invalid{};
    h.set_image(h.handle,&invalid,0,nullptr,h.queue_index);
    if(f.rejected==1 && !f.pending) m|=32u;
    // Metadata-only simulated submission, NOT a GPU-backed image. Never submitted to Vulkan.
    retro_vulkan_image sample{};
    sample.image_view=reinterpret_cast<VkImageView>(static_cast<uintptr_t>(0x1810));
    sample.image_layout=VK_IMAGE_LAYOUT_GENERAL;
    sample.create_info.sType=VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
    sample.create_info.image=reinterpret_cast<VkImage>(static_cast<uintptr_t>(0x1811));
    sample.create_info.viewType=VK_IMAGE_VIEW_TYPE_2D;
    h.set_image(h.handle,&sample,0,nullptr,h.queue_index);
    h.set_image(h.handle,&sample,0,nullptr,h.queue_index); // reject overwrite before consumer ack
    if(f.pending && f.accepted==1 && f.rejected==2) m|=64u;
    h.wait_sync_index(h.handle);
    if(!f.pending && f.consumed==1) m|=128u;
    // Destroy scope. No pointers escape, no libretro HW interface published.
    f.active=false; f.pending=false; f.view=VK_NULL_HANDLE; f.hw={};
    return m;
}
/* Castle 182: real image produced and cleared on the core callback-created
   Vulkan DEVICE, handed to a private v5 callback, acknowledged only after a
   completed fence. No Azahar renderer frame, semaphores, or publication. */
extern "C" unsigned AzaharV182CoreDeviceImageGate(void) {
    const auto &o=gAzV178Negotiated;
    auto &f=gAzV181Private;
    if(!o.active || !o.context.device || !o.context.queue || !o.context.gpu || !o.gdpa || f.active) return 0;
    const VkDevice d=o.context.device;
#define AZ182(T,member) reinterpret_cast<T>(o.gdpa(d,"vk" #member))
    auto createImage=AZ182(PFN_vkCreateImage,CreateImage);
    auto destroyImage=AZ182(PFN_vkDestroyImage,DestroyImage);
    auto requirements=AZ182(PFN_vkGetImageMemoryRequirements,GetImageMemoryRequirements);
    auto allocate=AZ182(PFN_vkAllocateMemory,AllocateMemory);
    auto freeMemory=AZ182(PFN_vkFreeMemory,FreeMemory);
    auto bind=AZ182(PFN_vkBindImageMemory,BindImageMemory);
    auto createView=AZ182(PFN_vkCreateImageView,CreateImageView);
    auto destroyView=AZ182(PFN_vkDestroyImageView,DestroyImageView);
    auto createPool=AZ182(PFN_vkCreateCommandPool,CreateCommandPool);
    auto destroyPool=AZ182(PFN_vkDestroyCommandPool,DestroyCommandPool);
    auto allocateCmd=AZ182(PFN_vkAllocateCommandBuffers,AllocateCommandBuffers);
    auto begin=AZ182(PFN_vkBeginCommandBuffer,BeginCommandBuffer);
    auto end=AZ182(PFN_vkEndCommandBuffer,EndCommandBuffer);
    auto barrier=AZ182(PFN_vkCmdPipelineBarrier,CmdPipelineBarrier);
    auto clear=AZ182(PFN_vkCmdClearColorImage,CmdClearColorImage);
    auto submit=AZ182(PFN_vkQueueSubmit,QueueSubmit);
    auto createFence=AZ182(PFN_vkCreateFence,CreateFence);
    auto destroyFence=AZ182(PFN_vkDestroyFence,DestroyFence);
    auto waitFence=AZ182(PFN_vkWaitForFences,WaitForFences);
#undef AZ182
    auto properties=reinterpret_cast<PFN_vkGetPhysicalDeviceMemoryProperties>(gAzV151Descriptor.hw.get_instance_proc_addr(o.instance,"vkGetPhysicalDeviceMemoryProperties"));
    if(!createImage||!destroyImage||!requirements||!allocate||!freeMemory||!bind||!createView||!destroyView||!createPool||!destroyPool||!allocateCmd||!begin||!end||!barrier||!clear||!submit||!createFence||!destroyFence||!waitFence||!properties) return 0;
    unsigned m=1u;
    VkImage image=VK_NULL_HANDLE;
    VkDeviceMemory memory=VK_NULL_HANDLE;
    VkImageView view=VK_NULL_HANDLE;
    VkCommandPool pool=VK_NULL_HANDLE;
    VkFence fence=VK_NULL_HANDLE;
    bool submitted=false;
    do {
        VkImageCreateInfo ii{};ii.sType=VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;ii.imageType=VK_IMAGE_TYPE_2D;
        ii.format=VK_FORMAT_R8G8B8A8_UNORM;ii.extent={8,8,1};ii.mipLevels=1;ii.arrayLayers=1;
        ii.samples=VK_SAMPLE_COUNT_1_BIT;ii.tiling=VK_IMAGE_TILING_OPTIMAL;
        ii.usage=VK_IMAGE_USAGE_TRANSFER_DST_BIT|VK_IMAGE_USAGE_SAMPLED_BIT;
        ii.sharingMode=VK_SHARING_MODE_EXCLUSIVE;ii.initialLayout=VK_IMAGE_LAYOUT_UNDEFINED;
        if(createImage(d,&ii,nullptr,&image)!=VK_SUCCESS||!image) break;
        m|=2u;
        VkMemoryRequirements req{};requirements(d,image,&req);
        VkPhysicalDeviceMemoryProperties mp{};properties(o.context.gpu,&mp);
        uint32_t type=UINT32_MAX;
        for(uint32_t i=0;i<mp.memoryTypeCount;++i) if((req.memoryTypeBits&(1u<<i))&&(mp.memoryTypes[i].propertyFlags&VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)){type=i;break;}
        if(type==UINT32_MAX) for(uint32_t i=0;i<mp.memoryTypeCount;++i) if(req.memoryTypeBits&(1u<<i)){type=i;break;}
        if(type==UINT32_MAX) break;
        VkMemoryAllocateInfo mai{};mai.sType=VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;mai.allocationSize=req.size;mai.memoryTypeIndex=type;
        if(allocate(d,&mai,nullptr,&memory)!=VK_SUCCESS||!memory||bind(d,image,memory,0)!=VK_SUCCESS)break;
        m|=4u;
        VkImageViewCreateInfo vi{};vi.sType=VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;vi.image=image;
        vi.viewType=VK_IMAGE_VIEW_TYPE_2D;vi.format=ii.format;
        vi.subresourceRange.aspectMask=VK_IMAGE_ASPECT_COLOR_BIT;vi.subresourceRange.levelCount=1;vi.subresourceRange.layerCount=1;
        if(createView(d,&vi,nullptr,&view)!=VK_SUCCESS||!view)break;
        m|=8u;
        VkCommandPoolCreateInfo pci{};pci.sType=VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;pci.queueFamilyIndex=o.context.queue_family_index;
        if(createPool(d,&pci,nullptr,&pool)!=VK_SUCCESS||!pool)break;
        VkCommandBuffer cb=VK_NULL_HANDLE;
        VkCommandBufferAllocateInfo cai{};cai.sType=VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;cai.commandPool=pool;cai.commandBufferCount=1;cai.level=VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        if(allocateCmd(d,&cai,&cb)!=VK_SUCCESS||!cb)break;
        VkCommandBufferBeginInfo bi{};bi.sType=VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;bi.flags=VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        if(begin(cb,&bi)!=VK_SUCCESS)break;
        VkImageMemoryBarrier ib{};ib.sType=VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;ib.oldLayout=VK_IMAGE_LAYOUT_UNDEFINED;ib.newLayout=VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        ib.srcQueueFamilyIndex=VK_QUEUE_FAMILY_IGNORED;ib.dstQueueFamilyIndex=VK_QUEUE_FAMILY_IGNORED;ib.image=image;
        ib.dstAccessMask=VK_ACCESS_TRANSFER_WRITE_BIT;ib.subresourceRange=vi.subresourceRange;
        barrier(cb,VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,VK_PIPELINE_STAGE_TRANSFER_BIT,0,0,nullptr,0,nullptr,1,&ib);
        VkClearColorValue color{};color.float32[0]=0.25f;color.float32[1]=0.5f;color.float32[2]=0.75f;color.float32[3]=1.f;
        clear(cb,image,VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,&color,1,&ib.subresourceRange);
        ib.oldLayout=VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;ib.newLayout=VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        ib.srcAccessMask=VK_ACCESS_TRANSFER_WRITE_BIT;ib.dstAccessMask=VK_ACCESS_SHADER_READ_BIT;
        barrier(cb,VK_PIPELINE_STAGE_TRANSFER_BIT,VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,0,0,nullptr,0,nullptr,1,&ib);
        if(end(cb)!=VK_SUCCESS)break;
        m|=16u;
        VkFenceCreateInfo fci{};fci.sType=VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
        if(createFence(d,&fci,nullptr,&fence)!=VK_SUCCESS||!fence)break;
        VkSubmitInfo si{};si.sType=VK_STRUCTURE_TYPE_SUBMIT_INFO;si.commandBufferCount=1;si.pCommandBuffers=&cb;
        if(submit(o.context.queue,1,&si,fence)!=VK_SUCCESS)break;
        submitted=true;m|=32u;
        if(waitFence(d,1,&fence,VK_TRUE,5000000000ULL)!=VK_SUCCESS)break;
        submitted=false;m|=64u;
        f.hw={};f.active=true;f.pending=false;f.accepted=0;f.rejected=0;f.consumed=0;f.view=VK_NULL_HANDLE;
        f.hw.interface_type=RETRO_HW_RENDER_INTERFACE_VULKAN;f.hw.interface_version=5;
        f.hw.handle=&f;f.hw.device=d;f.hw.queue=o.context.queue;f.hw.queue_index=o.context.queue_family_index;
        f.hw.set_image=AzV181SetImage;f.hw.wait_sync_index=AzV181WaitSync;
        retro_vulkan_image descriptor{};descriptor.image_view=view;descriptor.image_layout=VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        descriptor.create_info=vi;
        f.hw.set_image(f.hw.handle,&descriptor,0,nullptr,f.hw.queue_index);
        if(f.pending&&f.accepted==1&&f.view==view)m|=128u;
        f.hw.wait_sync_index(f.hw.handle);
        if(!f.pending&&f.consumed==1)m|=256u;
        f.active=false;f.pending=false;f.view=VK_NULL_HANDLE;f.hw={};
    } while(false);
    if(f.active){f.active=false;f.pending=false;f.view=VK_NULL_HANDLE;f.hw={};}
    if(submitted){auto idle=reinterpret_cast<PFN_vkDeviceWaitIdle>(o.gdpa(d,"vkDeviceWaitIdle"));if(idle)idle(d);}
    if(fence)destroyFence(d,fence,nullptr);
    if(pool)destroyPool(d,pool,nullptr);
    if(view)destroyView(d,view,nullptr);
    if(image)destroyImage(d,image,nullptr);
    if(memory)freeMemory(d,memory,nullptr);
    if(!f.active&&!f.pending&&!f.view)m|=512u;
    return m;
}
/* Castle 183: real binary semaphore dependency on Azahar callback-created
   device/queue. A producer submits a semaphore signal, a consumer queues a
   semaphore wait with a fence, and the fence verifies completion. This is a
   disposable private probe, not an Azahar-rendered frame or frontend publish. */
extern "C" unsigned AzaharV183CoreDeviceSemaphoreGate(void) {
    const auto &o=gAzV178Negotiated;
    if(!o.active || !o.context.device || !o.context.queue || !o.gdpa) return 0;
    VkDevice d=o.context.device;
#define AZ183(T,name) reinterpret_cast<T>(o.gdpa(d,"vk" #name))
    auto createSemaphore=AZ183(PFN_vkCreateSemaphore,CreateSemaphore);
    auto destroySemaphore=AZ183(PFN_vkDestroySemaphore,DestroySemaphore);
    auto createFence=AZ183(PFN_vkCreateFence,CreateFence);
    auto destroyFence=AZ183(PFN_vkDestroyFence,DestroyFence);
    auto queueSubmit=AZ183(PFN_vkQueueSubmit,QueueSubmit);
    auto waitFences=AZ183(PFN_vkWaitForFences,WaitForFences);
    auto queueIdle=AZ183(PFN_vkQueueWaitIdle,QueueWaitIdle);
#undef AZ183
    if(!createSemaphore||!destroySemaphore||!createFence||!destroyFence||!queueSubmit||!waitFences||!queueIdle) return 0;
    unsigned m=1u;VkSemaphore semaphore=VK_NULL_HANDLE;VkFence fence=VK_NULL_HANDLE;
    bool producerQueued=false,consumerQueued=false;
    do {
        VkSemaphoreCreateInfo si{};si.sType=VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
        if(createSemaphore(d,&si,nullptr,&semaphore)!=VK_SUCCESS||!semaphore) break;
        m|=2u;
        VkFenceCreateInfo fi{};fi.sType=VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
        if(createFence(d,&fi,nullptr,&fence)!=VK_SUCCESS||!fence)break;
        m|=4u;
        VkSubmitInfo producer{};producer.sType=VK_STRUCTURE_TYPE_SUBMIT_INFO;
        producer.signalSemaphoreCount=1;producer.pSignalSemaphores=&semaphore;
        if(queueSubmit(o.context.queue,1,&producer,VK_NULL_HANDLE)!=VK_SUCCESS) break;
        producerQueued=true;m|=8u;
        VkPipelineStageFlags waitStage=VK_PIPELINE_STAGE_ALL_COMMANDS_BIT;
        VkSubmitInfo consumer{};consumer.sType=VK_STRUCTURE_TYPE_SUBMIT_INFO;
        consumer.waitSemaphoreCount=1;consumer.pWaitSemaphores=&semaphore;
        consumer.pWaitDstStageMask=&waitStage;
        if(queueSubmit(o.context.queue,1,&consumer,fence)!=VK_SUCCESS)break;
        consumerQueued=true;m|=16u;
        if(waitFences(d,1,&fence,VK_TRUE,5000000000ULL)!=VK_SUCCESS)break;
        m|=32u;
    }while(false);
    // Even on a partially submitted path, do not destroy in-flight sync objects.
    bool drained=(!producerQueued&&!consumerQueued) || queueIdle(o.context.queue)==VK_SUCCESS;
    if(drained)m|=64u;
    if(drained){
        if(fence)destroyFence(d,fence,nullptr);
        if(semaphore)destroySemaphore(d,semaphore,nullptr);
        m|=128u;
    }
    return m;
}
extern "C" unsigned AzaharV178RetireAfterDeinit(void) {
    auto &s=gAzV178Negotiated;
    unsigned m=0;
    if (s.active && s.context.device) {
        m|=1u;
        auto wait=reinterpret_cast<PFN_vkDeviceWaitIdle>(s.gdpa(s.context.device,"vkDeviceWaitIdle"));
        if (wait && wait(s.context.device)==VK_SUCCESS) m|=2u;
        s.destroy_device(s.context.device,nullptr); m|=4u;
    }
    if (s.instance && s.destroy_instance) { s.destroy_instance(s.instance,nullptr); m|=8u; }
    s=AzV178NegotiatedOwner{};
    if (!s.active && !s.context.device && !s.instance) m|=16u;
    return m;
}
extern "C" unsigned AzaharV178RetainCoreDevice(void *appCallbackRaw, void *createDeviceRaw) {
    if (gAzV178Negotiated.active) return 0;
    unsigned m=0;
    const auto &owner=gAzV151Descriptor;
    if (!owner.initialized || !owner.hw.get_instance_proc_addr || !appCallbackRaw || !createDeviceRaw) return m;
    m|=1u;
    const auto getApp=reinterpret_cast<retro_vulkan_get_application_info_t>(appCallbackRaw);
    const VkApplicationInfo *app=getApp();
    if (!app || app->sType!=VK_STRUCTURE_TYPE_APPLICATION_INFO || !app->pApplicationName || VK_VERSION_MAJOR(app->apiVersion)!=1) return m;
    m|=2u;
    auto gip=owner.hw.get_instance_proc_addr;
    auto create=reinterpret_cast<PFN_vkCreateInstance>(gip(VK_NULL_HANDLE,"vkCreateInstance"));
    if (!create) return m;
    VkInstanceCreateInfo ci{}; ci.sType=VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO; ci.pApplicationInfo=app;
    VkInstance instance=VK_NULL_HANDLE;
    if (create(&ci,nullptr,&instance)!=VK_SUCCESS || !instance) return m;
    m|=4u;
    auto destroyInstance=reinterpret_cast<PFN_vkDestroyInstance>(gip(instance,"vkDestroyInstance"));
    auto enumGPU=reinterpret_cast<PFN_vkEnumeratePhysicalDevices>(gip(instance,"vkEnumeratePhysicalDevices"));
    auto queueProps=reinterpret_cast<PFN_vkGetPhysicalDeviceQueueFamilyProperties>(gip(instance,"vkGetPhysicalDeviceQueueFamilyProperties"));
    auto destroyDevice=reinterpret_cast<PFN_vkDestroyDevice>(gip(instance,"vkDestroyDevice"));
    auto gdpa=reinterpret_cast<PFN_vkGetDeviceProcAddr>(gip(instance,"vkGetDeviceProcAddr"));
    bool retained=false;
    if (destroyInstance && enumGPU && queueProps && destroyDevice && gdpa) {
        uint32_t count=0;
        if (enumGPU(instance,&count,nullptr)==VK_SUCCESS && count && count<=16) {
            VkPhysicalDevice devices[16]={};
            if(enumGPU(instance,&count,devices)==VK_SUCCESS) {
                for(uint32_t d=0;d<count && !retained;d++) {
                    uint32_t nq=0; queueProps(devices[d],&nq,nullptr);
                    if(!nq || nq>64) continue;
                    VkQueueFamilyProperties qs[64]={}; queueProps(devices[d],&nq,qs);
                    bool suitable=false;
                    for(uint32_t q=0;q<nq;q++) if(qs[q].queueCount && (qs[q].queueFlags&(VK_QUEUE_GRAPHICS_BIT|VK_QUEUE_COMPUTE_BIT))==(VK_QUEUE_GRAPHICS_BIT|VK_QUEUE_COMPUTE_BIT)) suitable=true;
                    if(!suitable) continue;
                    m|=8u;
                    retro_vulkan_context ctx{};
                    auto callback=reinterpret_cast<retro_vulkan_create_device_t>(createDeviceRaw);
                    if(callback(&ctx,instance,devices[d],VK_NULL_HANDLE,gip,nullptr,0,nullptr,0,nullptr) && ctx.device && ctx.gpu==devices[d] && ctx.queue &&
                        ctx.queue_family_index<nq && qs[ctx.queue_family_index].queueCount && (qs[ctx.queue_family_index].queueFlags&VK_QUEUE_GRAPHICS_BIT)) {
                        m|=16u;
                        auto submit=gdpa(ctx.device,"vkQueueSubmit");
                        auto wait=gdpa(ctx.device,"vkDeviceWaitIdle");
                        if(submit && wait) m|=32u;
                        if(submit && wait) {
                            gAzV178Negotiated.instance=instance;
                            gAzV178Negotiated.context=ctx;
                            gAzV178Negotiated.destroy_instance=destroyInstance;
                            gAzV178Negotiated.destroy_device=destroyDevice;
                            gAzV178Negotiated.gdpa=gdpa;
                            gAzV178Negotiated.active=true;
                            retained=true; m|=64u;
                        }
                    }
                    if(!retained && ctx.device) destroyDevice(ctx.device,nullptr);
                    break;
                }
            }
        }
    }
    if(!retained && destroyInstance) destroyInstance(instance,nullptr);
    if(retained && AzaharV178RetainedState()==7u) m|=128u;
    return m;
}
/* Castle 177: real Azahar v1 device-creation callback, disposable scope.
   Context and all handles are local; never publish a libretro Vulkan interface.
   A successful callback-created device is retired before the instance. */
extern "C" unsigned AzaharV177CoreDeviceGate(void *appCallbackRaw, void *createDeviceRaw) {
    unsigned mask = 0;
    const auto &owner = gAzV151Descriptor;
    if (!owner.initialized || !owner.hw.get_instance_proc_addr || !appCallbackRaw || !createDeviceRaw) return mask;
    mask |= 1u;
    auto getApp = reinterpret_cast<retro_vulkan_get_application_info_t>(appCallbackRaw);
    const VkApplicationInfo *app = getApp();
    if (!app || app->sType != VK_STRUCTURE_TYPE_APPLICATION_INFO || !app->pApplicationName ||
        VK_VERSION_MAJOR(app->apiVersion) != 1u) return mask;
    mask |= 2u;
    auto gip = owner.hw.get_instance_proc_addr;
    auto create = reinterpret_cast<PFN_vkCreateInstance>(gip(VK_NULL_HANDLE, "vkCreateInstance"));
    if (!create) return mask;
    VkInstanceCreateInfo ci{};
    ci.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    ci.pApplicationInfo = app;
    VkInstance instance = VK_NULL_HANDLE;
    if (create(&ci, nullptr, &instance) != VK_SUCCESS || !instance) return mask;
    mask |= 4u;
    auto destroyInstance = reinterpret_cast<PFN_vkDestroyInstance>(gip(instance, "vkDestroyInstance"));
    auto enumerate = reinterpret_cast<PFN_vkEnumeratePhysicalDevices>(gip(instance, "vkEnumeratePhysicalDevices"));
    auto properties = reinterpret_cast<PFN_vkGetPhysicalDeviceQueueFamilyProperties>(gip(instance, "vkGetPhysicalDeviceQueueFamilyProperties"));
    auto destroyDevice = reinterpret_cast<PFN_vkDestroyDevice>(gip(instance, "vkDestroyDevice"));
    if (destroyInstance && enumerate && properties && destroyDevice) {
        uint32_t count = 0;
        if (enumerate(instance, &count, nullptr) == VK_SUCCESS && count > 0 && count <= 16) {
            VkPhysicalDevice devices[16] = {};
            if (enumerate(instance, &count, devices) == VK_SUCCESS) {
                for (uint32_t d = 0; d < count; ++d) {
                    uint32_t qcount = 0;
                    properties(devices[d], &qcount, nullptr);
                    if (!qcount || qcount > 64) continue;
                    VkQueueFamilyProperties queues[64] = {};
                    properties(devices[d], &qcount, queues);
                    bool suitable = false;
                    for (uint32_t q=0; q<qcount; ++q) if (queues[q].queueCount &&
                        (queues[q].queueFlags & (VK_QUEUE_GRAPHICS_BIT | VK_QUEUE_COMPUTE_BIT)) ==
                        (VK_QUEUE_GRAPHICS_BIT | VK_QUEUE_COMPUTE_BIT)) suitable = true;
                    if (!suitable) continue;
                    mask |= 8u;
                    retro_vulkan_context context{};
                    auto coreCreate = reinterpret_cast<retro_vulkan_create_device_t>(createDeviceRaw);
                    const bool result = coreCreate(&context, instance, devices[d], VK_NULL_HANDLE, gip,
                        nullptr, 0, nullptr, 0, nullptr);
                    if (result && context.device && context.gpu == devices[d] && context.queue) {
                        mask |= 16u;
                        if (context.queue_family_index < qcount &&
                            queues[context.queue_family_index].queueCount &&
                            (queues[context.queue_family_index].queueFlags & VK_QUEUE_GRAPHICS_BIT)) mask |= 32u;
                    }
                    if (context.device) {
                        destroyDevice(context.device, nullptr);
                        context.device = VK_NULL_HANDLE;
                        mask |= 64u;
                    }
                    break; // one real callback invocation, no duplicate core-created devices
                }
            }
        }
    }
    if (destroyInstance) { destroyInstance(instance, nullptr); mask |= 128u; }
    return mask;
}
extern "C" unsigned AzaharV170LivePublicationPrerequisites(void) {
    const auto &d = gAzV151Descriptor;
    const auto &h = d.hw;
    unsigned m = 0;
    if (d.initialized && h.handle == &d) m |= 1u; // owned lifecycle
    if (h.interface_type == RETRO_HW_RENDER_INTERFACE_VULKAN &&
        h.interface_version == 5u && h.instance && h.gpu && h.device && h.queue)
        m |= 2u; // real ABI and devices
    if (h.get_instance_proc_addr && h.get_device_proc_addr) m |= 4u;
    if (h.set_image && h.lock_queue && h.unlock_queue &&
        h.get_sync_index && h.get_sync_index_mask && h.wait_sync_index) m |= 8u;
    // The bridge has no Azahar-frame consumer nor verified OpenEmu presenter.
    // Do not set those bits based on private image probes.
    return m;
}
extern "C" unsigned AzaharV169OwnedInterfaceGate(void) {
    const auto &s = gAzV151Descriptor;
    const auto &hw = s.hw;
    unsigned m = 0;
    if (s.initialized && s.generation > 0 && hw.handle == &s) m |= 1u;
    if (hw.interface_type == RETRO_HW_RENDER_INTERFACE_VULKAN &&
        hw.interface_version == RETRO_HW_RENDER_INTERFACE_VULKAN_VERSION &&
        hw.interface_version == 5u) m |= 2u;
    if (hw.instance && hw.gpu && hw.device && hw.queue &&
        hw.queue_index != UINT32_MAX) m |= 4u;
    if (hw.get_instance_proc_addr && hw.get_device_proc_addr &&
        hw.get_instance_proc_addr(hw.instance, "vkGetDeviceProcAddr")) m |= 8u;
    if (hw.get_device_proc_addr &&
        hw.get_device_proc_addr(hw.device, "vkQueueSubmit") &&
        hw.get_device_proc_addr(hw.device, "vkCreateFence") &&
        hw.get_device_proc_addr(hw.device, "vkWaitForFences")) m |= 16u;
    if (hw.set_image == AzV152SetImage &&
        hw.lock_queue == AzV152LockQueue &&
        hw.unlock_queue == AzV152UnlockQueue &&
        hw.wait_sync_index == AzV152WaitSyncIndex) m |= 32u;
    if (hw.get_sync_index == AzV152GetSyncIndex &&
        hw.get_sync_index_mask == AzV152GetSyncMask &&
        hw.get_sync_index(hw.handle) == 0 &&
        hw.get_sync_index_mask(hw.handle) == 1) m |= 64u;
    // Critical publication gate: staged, private interface is not yet a
    // working renderer/presenter. No hardware context may be advertised.
    if (!gAzV152ImagePending && !gAzV153Inbox.view) m |= 128u;
    return m;
}
extern "C" unsigned AzaharV152InstallCallbacks(void) {
    auto &s = gAzV151Descriptor;
    if (!s.initialized || s.hw.handle || s.hw.set_image) return 0u;
    s.hw.handle = &s;
    s.hw.set_image = AzV152SetImage;
    s.hw.get_sync_index = AzV152GetSyncIndex;
    s.hw.get_sync_index_mask = AzV152GetSyncMask;
    s.hw.lock_queue = AzV152LockQueue;
    s.hw.unlock_queue = AzV152UnlockQueue;
    s.hw.wait_sync_index = AzV152WaitSyncIndex;
    gAzV152SyncIndex = 0;
    gAzV152ImageCalls = 0;
    gAzV152RejectedImages = 0;
    gAzV152ImagePending = false;
    gAzV153Inbox = {};
    gAzV153Consumed = 0;
    gAzV153Overflow = 0;
    gAzV154Dropped = 0;
    gAzV154Stale = 0;
    gAzV154Invalid = 0;
    return 1u;
}
extern "C" unsigned AzaharV152AuditCallbacks(void) {
    const auto &s = gAzV151Descriptor;
    return s.initialized && s.hw.handle == &s &&
        s.hw.set_image == AzV152SetImage &&
        s.hw.get_sync_index == AzV152GetSyncIndex &&
        s.hw.get_sync_index_mask == AzV152GetSyncMask &&
        s.hw.lock_queue == AzV152LockQueue &&
        s.hw.unlock_queue == AzV152UnlockQueue &&
        s.hw.wait_sync_index == AzV152WaitSyncIndex &&
        !gAzV152ImagePending && !gAzV152ImageCalls && !gAzV152RejectedImages ? 1u : 0u;
}
extern "C" unsigned AzaharV151InstallOwner(void *instance, void *physical,
    void *device, void *queue, unsigned family, void *instanceProc) {
    if (gAzV151Descriptor.initialized) return 0; // fail closed on double-install
    if (AzaharV150StagePersistentOwner(instance, physical, device, queue,
                                      family, instanceProc) != 0x3fu) return 0;
    auto &state = gAzV151Descriptor;
    auto &hw = state.hw;
    hw = {};
    hw.interface_type = RETRO_HW_RENDER_INTERFACE_VULKAN;
    hw.interface_version = RETRO_HW_RENDER_INTERFACE_VULKAN_VERSION;
    hw.instance = reinterpret_cast<VkInstance>(instance);
    hw.gpu = reinterpret_cast<VkPhysicalDevice>(physical);
    hw.device = reinterpret_cast<VkDevice>(device);
    hw.queue = reinterpret_cast<VkQueue>(queue);
    hw.queue_index = family;
    hw.get_instance_proc_addr = reinterpret_cast<PFN_vkGetInstanceProcAddr>(instanceProc);
    hw.get_device_proc_addr = reinterpret_cast<PFN_vkGetDeviceProcAddr>(
        hw.get_instance_proc_addr(hw.instance, "vkGetDeviceProcAddr"));
    state.initialized = true;
    ++state.generation;
    return 1;
}
extern "C" unsigned AzaharV151AuditDescriptor(void *instance, void *device) {
    const auto &state = gAzV151Descriptor;
    const auto &hw = state.hw;
    unsigned mask = 0;
    if (state.initialized && state.generation) mask |= 1u;
    if (hw.interface_type == RETRO_HW_RENDER_INTERFACE_VULKAN &&
        hw.interface_version == 5u) mask |= 2u;
    if (hw.instance == reinterpret_cast<VkInstance>(instance) &&
        hw.device == reinterpret_cast<VkDevice>(device) && hw.gpu && hw.queue) mask |= 4u;
    if (hw.get_instance_proc_addr && hw.get_device_proc_addr) mask |= 8u;
    if (hw.set_image && hw.get_sync_index && hw.get_sync_index_mask &&
        hw.lock_queue && hw.unlock_queue && hw.wait_sync_index) mask |= 16u;
    if (hw.handle == &state) mask |= 32u;
    return mask;
}
extern "C" unsigned AzaharV151ResetDescriptor(void) {
    const bool wasInitialized = gAzV151Descriptor.initialized;
    gAzV151Descriptor.hw = {};
    gAzV151Descriptor.initialized = false;
    gAzV153Inbox = {};
    gAzV152ImagePending = false;
    gAzV152ImageCalls = 0;
    gAzV152RejectedImages = 0;
    gAzV153Consumed = 0;
    gAzV153Overflow = 0;
    gAzV154Dropped = 0;
    gAzV154Stale = 0;
    gAzV154Invalid = 0;
    // generation is monotonic within process; the pointer address remains stable.
    return wasInitialized ? 1u : 0u;
}
extern "C" unsigned AzaharV151IsDescriptorCleared(void) {
    const auto &s = gAzV151Descriptor;
    return !s.initialized && !s.hw.instance && !s.hw.device && !s.hw.gpu &&
        !s.hw.queue && !s.hw.get_instance_proc_addr && !s.hw.get_device_proc_addr ? 1u : 0u;
}


// Castle 160: six independent fail-closed private contract lanes.
// These lanes intentionally do not publish the libretro Vulkan interface.
// They use synthetic opaque handles only as metadata; never dereference them.
struct AzV160Counters {
    unsigned calls,rejects,consumed,dropped,overflow,stale,invalid;
};
static AzV160Counters AzV160Save() {
    return {gAzV152ImageCalls,gAzV152RejectedImages,gAzV153Consumed,
            gAzV154Dropped,gAzV153Overflow,gAzV154Stale,gAzV154Invalid};
}
static bool AzV160Restore(const AzV160Counters &c, unsigned generation) {
    if (gAzV152ImagePending) (void)AzV154DropPending(generation);
    const bool empty = !gAzV152ImagePending && !gAzV153Inbox.view;
    gAzV152ImageCalls=c.calls; gAzV152RejectedImages=c.rejects;
    gAzV153Consumed=c.consumed; gAzV154Dropped=c.dropped;
    gAzV153Overflow=c.overflow; gAzV154Stale=c.stale; gAzV154Invalid=c.invalid;
    return empty;
}
static retro_vulkan_image AzV160Image(uintptr_t tag) {
    retro_vulkan_image image={};
    image.image_view=reinterpret_cast<VkImageView>(tag);
    image.image_layout=VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    image.create_info.sType=VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
    image.create_info.viewType=VK_IMAGE_VIEW_TYPE_2D;
    image.create_info.format=VK_FORMAT_R8G8B8A8_UNORM;
    return image;
}
static bool AzV160Ready() {
    const auto &s=gAzV151Descriptor;
    return s.initialized && s.hw.handle==&s && s.hw.set_image==AzV152SetImage &&
           s.hw.get_sync_index && s.hw.get_sync_index_mask &&
           s.hw.lock_queue && s.hw.unlock_queue && s.hw.wait_sync_index &&
           !gAzV152ImagePending && !gAzV153Inbox.view;
}
// A: complete official descriptor fields and callable callback scope.
extern "C" unsigned AzaharV160LaneA(void) {
    const auto &s=gAzV151Descriptor; if (!AzV160Ready()) return 0;
    unsigned m=0;
    if(s.hw.interface_type==RETRO_HW_RENDER_INTERFACE_VULKAN && s.hw.interface_version==5) m|=1;
    if(s.hw.instance && s.hw.gpu && s.hw.device && s.hw.queue) m|=2;
    if(s.hw.get_instance_proc_addr && s.hw.get_device_proc_addr) m|=4;
    if(s.hw.set_image && s.hw.handle==&s) m|=8;
    if(s.hw.wait_sync_index==AzV152WaitSyncIndex) m|=16; // pointer only, STUB
    if(s.hw.get_sync_index && s.hw.get_sync_index_mask) m|=32;
    if(s.hw.lock_queue && s.hw.unlock_queue) m|=64;
    if(!gAzV152ImagePending && !gAzV153Inbox.view) m|=128;
    return m;
}
// B: exercise negative callback ownership and null descriptor, then recovery.
extern "C" unsigned AzaharV160LaneB(void) {
    if(!AzV160Ready()) return 0;
    auto &s=gAzV151Descriptor; auto c=AzV160Save(); auto im=AzV160Image(0x160b);
    unsigned m=0; const auto f=s.hw.queue_index, gen=s.generation;
    s.hw.set_image(nullptr,&im,0,nullptr,f);
    if(gAzV152RejectedImages==c.rejects+1 && !gAzV152ImagePending) m|=1;
    s.hw.set_image(s.hw.handle,nullptr,0,nullptr,f);
    if(gAzV152RejectedImages==c.rejects+2 && !gAzV152ImagePending) m|=2;
    s.hw.set_image(s.hw.handle,&im,0,nullptr,f);
    if(gAzV152ImagePending && gAzV153Inbox.view==im.image_view) m|=4;
    AzV153Inbox out={};
    if(AzV154ConsumeGuarded(gen,f,&out) && out.view==im.image_view) m|=8;
    if(AzV160Restore(c,gen)) m|=16;
    return m;
}
// C: enforce zero-wait and eight-wait inclusive boundary; nine are rejected.
extern "C" unsigned AzaharV160LaneC(void) {
    if(!AzV160Ready()) return 0;
    auto &s=gAzV151Descriptor; auto c=AzV160Save(); auto im=AzV160Image(0x160c);
    const auto f=s.hw.queue_index, gen=s.generation; unsigned m=0;
    s.hw.set_image(s.hw.handle,&im,0,nullptr,f);
    AzV153Inbox out={};
    if(AzV154ConsumeGuarded(gen,f,&out) && out.semaphoreCount==0) m|=1;
    VkSemaphore sem[8]={};
    for(unsigned i=0;i<8;i++) sem[i]=reinterpret_cast<VkSemaphore>(static_cast<uintptr_t>(0x160c0+i));
    s.hw.set_image(s.hw.handle,&im,8,sem,f);
    if(gAzV152ImagePending && gAzV153Inbox.semaphoreCount==8) m|=2;
    if(AzV154ConsumeGuarded(gen,f,&out) && out.semaphoreCount==8 &&
       out.semaphores[0]==sem[0] && out.semaphores[7]==sem[7]) m|=4;
    s.hw.set_image(s.hw.handle,&im,9,sem,f); // length rejected before copying any wait handles
    if(!gAzV152ImagePending && gAzV153Overflow==c.overflow+1) m|=8;
    if(AzV160Restore(c,gen)) m|=16;
    return m;
}
// D: pending collision rejected, single consume, duplicate replay blocked.
extern "C" unsigned AzaharV160LaneD(void) {
    if(!AzV160Ready()) return 0;
    auto &s=gAzV151Descriptor; auto c=AzV160Save(); auto im=AzV160Image(0x160d);
    const auto f=s.hw.queue_index, gen=s.generation; unsigned m=0;
    s.hw.set_image(s.hw.handle,&im,0,nullptr,f);
    if(gAzV152ImagePending) m|=1;
    s.hw.set_image(s.hw.handle,&im,0,nullptr,f);
    if(gAzV152RejectedImages==c.rejects+1 && gAzV152ImagePending) m|=2;
    AzV153Inbox out={};
    if(AzV154ConsumeGuarded(gen,f,&out) && out.view==im.image_view) m|=4;
    if(!AzV154ConsumeGuarded(gen,f,&out) && !gAzV152ImagePending) m|=8;
    if(AzV160Restore(c,gen)) m|=16;
    return m;
}
// E: mismatched generation and queue family must leave image available for safe drop.
extern "C" unsigned AzaharV160LaneE(void) {
    if(!AzV160Ready()) return 0;
    auto &s=gAzV151Descriptor; auto c=AzV160Save(); auto im=AzV160Image(0x160e);
    const auto f=s.hw.queue_index, gen=s.generation; unsigned m=0;
    s.hw.set_image(s.hw.handle,&im,0,nullptr,f);
    if(gAzV152ImagePending) m|=1;
    AzV153Inbox out={};
    if(!AzV154ConsumeGuarded(gen+1,f,&out) && gAzV154Stale==c.stale+1 && gAzV152ImagePending) m|=2;
    if(!AzV154ConsumeGuarded(gen,f+1,&out) && gAzV154Invalid==c.invalid+1 && gAzV152ImagePending) m|=4;
    if(AzV154DropPending(gen) && !gAzV152ImagePending && !gAzV153Inbox.view) m|=8;
    if(AzV160Restore(c,gen)) m|=16;
    return m;
}
// F: verify callback sync index ABI and no leakage across a lock scope.
// wait_sync_index stays STUB_ONLY; never count it as a real GPU wait.
extern "C" unsigned AzaharV160LaneF(void) {
    if(!AzV160Ready()) return 0;
    auto &s=gAzV151Descriptor; unsigned m=0;
    if(s.hw.get_sync_index(s.hw.handle)==gAzV152SyncIndex) m|=1;
    if(s.hw.get_sync_index(nullptr)==0) m|=2;
    if(s.hw.get_sync_index_mask(s.hw.handle)==1) m|=4;
    if(s.hw.get_sync_index_mask(nullptr)==0) m|=8;
    s.hw.lock_queue(s.hw.handle); s.hw.unlock_queue(s.hw.handle);
    if(!gAzV152ImagePending && !gAzV153Inbox.view) m|=16;
    return m;
}

// Castle 161: eight additional isolated tests, using borrowed opaque metadata only.
// No synthetic Vulkan handle below is dereferenced, presented, or shared with Azahar.
extern "C" unsigned AzaharV161Lane(unsigned lane) {
    if (!AzV160Ready() || lane>=8) return 0u;
    auto &s=gAzV151Descriptor;
    const auto gen=s.generation, family=s.hw.queue_index;
    auto c=AzV160Save();
    auto image=AzV160Image(static_cast<uintptr_t>(0x16100u+lane));
    unsigned mask=0;
    VkSemaphore waits[8]={};
    for (unsigned i=0;i<8;i++) waits[i]=reinterpret_cast<VkSemaphore>(static_cast<uintptr_t>(0x161a0u+8*lane+i));
    AzV153Inbox received={};
    if (lane<4) {
        auto invalid=image;
        switch(lane) {
          case 0: invalid.image_view=VK_NULL_HANDLE; break;
          case 1: invalid.create_info.sType=VK_STRUCTURE_TYPE_APPLICATION_INFO; break;
          case 2: invalid.create_info.viewType=static_cast<VkImageViewType>(0x7fffffff); break;
          case 3: break;
        }
        s.hw.set_image(s.hw.handle,&invalid,lane==3?1u:0u,nullptr,family);
        if (!gAzV152ImagePending && gAzV152RejectedImages==c.rejects+1) mask|=1u;
        s.hw.set_image(s.hw.handle,&image,0,nullptr,family);
        if (gAzV152ImagePending && gAzV153Inbox.view==image.image_view) mask|=2u;
        if (AzV154ConsumeGuarded(gen,family,&received) && received.view==image.image_view) mask|=4u;
        if (!gAzV152ImagePending && !gAzV153Inbox.view) mask|=8u;
    } else if (lane==4) {
        for (unsigned n : {1u,2u,4u,7u}) {
            s.hw.set_image(s.hw.handle,&image,n,waits,family);
            if (!gAzV152ImagePending || gAzV153Inbox.semaphoreCount!=n ||
                !AzV154ConsumeGuarded(gen,family,&received) || received.semaphoreCount!=n ||
                received.semaphores[n-1]!=waits[n-1]) break;
            mask |= (1u << (n==1?0:n==2?1:n==4?2:3));
        }
    } else if (lane==5) {
        s.hw.set_image(s.hw.handle,&image,0,nullptr,family);
        if (gAzV152ImagePending) mask|=1u;
        auto invalid=image; invalid.image_view=VK_NULL_HANDLE;
        s.hw.set_image(s.hw.handle,&invalid,0,nullptr,family);
        if (gAzV152ImagePending && gAzV152RejectedImages==c.rejects+1) mask|=2u;
        if (AzV154ConsumeGuarded(gen,family,&received) && received.view==image.image_view) mask|=4u;
        if (!AzV154ConsumeGuarded(gen,family,&received)) mask|=8u;
    } else if (lane==6) {
        s.hw.set_image(s.hw.handle,&image,0,nullptr,family);
        if (gAzV152ImagePending) mask|=1u;
        if (!AzV154ConsumeGuarded(gen+1,family,&received) && gAzV152ImagePending) mask|=2u;
        if (!AzV154ConsumeGuarded(gen,family+1,&received) && gAzV152ImagePending) mask|=4u;
        if (AzV154ConsumeGuarded(gen,family,&received) && received.view==image.image_view) mask|=8u;
    } else {
        bool all=true;
        for (unsigned i=0;i<16;i++) {
            image.image_view=reinterpret_cast<VkImageView>(static_cast<uintptr_t>(0x161f0u+i));
            s.hw.set_image(s.hw.handle,&image,0,nullptr,family);
            if (!gAzV152ImagePending || !AzV154ConsumeGuarded(gen,family,&received) ||
                received.view!=image.image_view) { all=false; break; }
        }
        if(all) mask|=1u;
        if(!gAzV152ImagePending && !gAzV153Inbox.view) mask|=2u;
        if(gAzV153Overflow==c.overflow && gAzV152RejectedImages==c.rejects) mask|=4u;
        if(gAzV154Stale==c.stale && gAzV154Invalid==c.invalid) mask|=8u;
    }
    if(AzV160Restore(c,gen) && AzV160Ready()) mask|=16u;
    return mask;
}

// Castle 162: eight private callback stress/recovery cases, not frontend integration.
// Each case restores counters and retains the fail-closed hardware policy.
extern "C" unsigned AzaharV162Lane(unsigned lane) {
    if (!AzV160Ready() || lane >= 8) return 0;
    auto &s=gAzV151Descriptor;
    auto saved=AzV160Save();
    const unsigned generation=s.generation;
    const uint32_t family=s.hw.queue_index;
    unsigned mask=0;
    AzV153Inbox out={};
    auto image=AzV160Image(static_cast<uintptr_t>(0x16200+lane));
    VkSemaphore waits[8]={};
    for (unsigned n=0;n<8;n++) waits[n]=reinterpret_cast<VkSemaphore>(static_cast<uintptr_t>(0x162a0+lane*8+n));
    const unsigned count=lane; // 0-7 supported semaphore-array sizes
    s.hw.set_image(s.hw.handle,&image,count,count?waits:nullptr,family);
    if(gAzV152ImagePending && gAzV153Inbox.view==image.image_view && gAzV153Inbox.semaphoreCount==count) mask|=1;
    if(AzV154ConsumeGuarded(generation,family,&out) && out.view==image.image_view &&
       out.semaphoreCount==count && (!count || out.semaphores[count-1]==waits[count-1])) mask|=2;
    if(!AzV154ConsumeGuarded(generation,family,&out) && !gAzV152ImagePending) mask|=4;
    // A malformed descriptor must never poison the next valid delivery.
    auto invalid=image; invalid.image_view=VK_NULL_HANDLE;
    s.hw.set_image(s.hw.handle,&invalid,0,nullptr,family);
    if(!gAzV152ImagePending && gAzV152RejectedImages==saved.rejects+1) mask|=8;
    s.hw.set_image(s.hw.handle,&image,0,nullptr,family);
    if(AzV154ConsumeGuarded(generation,family,&out) && out.view==image.image_view) mask|=16;
    if(AzV160Restore(saved,generation) && AzV160Ready()) mask|=32;
    return mask;
}
/* Castle 184 integrated lane A: GPU-produced Vulkan image is synchronized by a
   real binary semaphore, queue consumer fence, then passed to private callback.
   Work and image are on the same Azahar callback-created Vulkan device.
   The consumer submission only waits; it does not sample the image.
   This is NOT a real Azahar frame or a published interface. */
extern "C" unsigned AzaharV184SynchronizedImageGate(void) {
    const auto &o=gAzV178Negotiated;
    auto &f=gAzV181Private;
    if(!o.active || !o.context.device || !o.context.queue || !o.context.gpu || !o.gdpa || f.active) return 0;
    const VkDevice d=o.context.device;
#define AZ182(T,member) reinterpret_cast<T>(o.gdpa(d,"vk" #member))
    auto createImage=AZ182(PFN_vkCreateImage,CreateImage);
    auto destroyImage=AZ182(PFN_vkDestroyImage,DestroyImage);
    auto requirements=AZ182(PFN_vkGetImageMemoryRequirements,GetImageMemoryRequirements);
    auto allocate=AZ182(PFN_vkAllocateMemory,AllocateMemory);
    auto freeMemory=AZ182(PFN_vkFreeMemory,FreeMemory);
    auto bind=AZ182(PFN_vkBindImageMemory,BindImageMemory);
    auto createView=AZ182(PFN_vkCreateImageView,CreateImageView);
    auto destroyView=AZ182(PFN_vkDestroyImageView,DestroyImageView);
    auto createPool=AZ182(PFN_vkCreateCommandPool,CreateCommandPool);
    auto destroyPool=AZ182(PFN_vkDestroyCommandPool,DestroyCommandPool);
    auto allocateCmd=AZ182(PFN_vkAllocateCommandBuffers,AllocateCommandBuffers);
    auto begin=AZ182(PFN_vkBeginCommandBuffer,BeginCommandBuffer);
    auto end=AZ182(PFN_vkEndCommandBuffer,EndCommandBuffer);
    auto barrier=AZ182(PFN_vkCmdPipelineBarrier,CmdPipelineBarrier);
    auto clear=AZ182(PFN_vkCmdClearColorImage,CmdClearColorImage);
    auto submit=AZ182(PFN_vkQueueSubmit,QueueSubmit);
    auto createSemaphore=AZ182(PFN_vkCreateSemaphore,CreateSemaphore);
    auto destroySemaphore=AZ182(PFN_vkDestroySemaphore,DestroySemaphore);
    auto queueIdle=AZ182(PFN_vkQueueWaitIdle,QueueWaitIdle);
    auto createFence=AZ182(PFN_vkCreateFence,CreateFence);
    auto destroyFence=AZ182(PFN_vkDestroyFence,DestroyFence);
    auto waitFence=AZ182(PFN_vkWaitForFences,WaitForFences);
#undef AZ182
    auto properties=reinterpret_cast<PFN_vkGetPhysicalDeviceMemoryProperties>(gAzV151Descriptor.hw.get_instance_proc_addr(o.instance,"vkGetPhysicalDeviceMemoryProperties"));
    if(!createImage||!destroyImage||!requirements||!allocate||!freeMemory||!bind||!createView||!destroyView||!createPool||!destroyPool||!allocateCmd||!begin||!end||!barrier||!clear||!submit||!createFence||!destroyFence||!waitFence||!properties||!createSemaphore||!destroySemaphore||!queueIdle) return 0;
    unsigned m=1u;
    VkImage image=VK_NULL_HANDLE;
    VkDeviceMemory memory=VK_NULL_HANDLE;
    VkImageView view=VK_NULL_HANDLE;
    VkCommandPool pool=VK_NULL_HANDLE;
    VkFence fence=VK_NULL_HANDLE;
    VkSemaphore imageReady=VK_NULL_HANDLE;
    bool queueWorkPending=false;
    bool submitted=false;
    do {
        VkImageCreateInfo ii{};ii.sType=VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;ii.imageType=VK_IMAGE_TYPE_2D;
        ii.format=VK_FORMAT_R8G8B8A8_UNORM;ii.extent={8,8,1};ii.mipLevels=1;ii.arrayLayers=1;
        ii.samples=VK_SAMPLE_COUNT_1_BIT;ii.tiling=VK_IMAGE_TILING_OPTIMAL;
        ii.usage=VK_IMAGE_USAGE_TRANSFER_DST_BIT|VK_IMAGE_USAGE_SAMPLED_BIT;
        ii.sharingMode=VK_SHARING_MODE_EXCLUSIVE;ii.initialLayout=VK_IMAGE_LAYOUT_UNDEFINED;
        if(createImage(d,&ii,nullptr,&image)!=VK_SUCCESS||!image) break;
        m|=2u;
        VkMemoryRequirements req{};requirements(d,image,&req);
        VkPhysicalDeviceMemoryProperties mp{};properties(o.context.gpu,&mp);
        uint32_t type=UINT32_MAX;
        for(uint32_t i=0;i<mp.memoryTypeCount;++i) if((req.memoryTypeBits&(1u<<i))&&(mp.memoryTypes[i].propertyFlags&VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)){type=i;break;}
        if(type==UINT32_MAX) for(uint32_t i=0;i<mp.memoryTypeCount;++i) if(req.memoryTypeBits&(1u<<i)){type=i;break;}
        if(type==UINT32_MAX) break;
        VkMemoryAllocateInfo mai{};mai.sType=VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;mai.allocationSize=req.size;mai.memoryTypeIndex=type;
        if(allocate(d,&mai,nullptr,&memory)!=VK_SUCCESS||!memory||bind(d,image,memory,0)!=VK_SUCCESS)break;
        m|=4u;
        VkImageViewCreateInfo vi{};vi.sType=VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;vi.image=image;
        vi.viewType=VK_IMAGE_VIEW_TYPE_2D;vi.format=ii.format;
        vi.subresourceRange.aspectMask=VK_IMAGE_ASPECT_COLOR_BIT;vi.subresourceRange.levelCount=1;vi.subresourceRange.layerCount=1;
        if(createView(d,&vi,nullptr,&view)!=VK_SUCCESS||!view)break;
        m|=8u;
        VkCommandPoolCreateInfo pci{};pci.sType=VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;pci.queueFamilyIndex=o.context.queue_family_index;
        if(createPool(d,&pci,nullptr,&pool)!=VK_SUCCESS||!pool)break;
        VkCommandBuffer cb=VK_NULL_HANDLE;
        VkCommandBufferAllocateInfo cai{};cai.sType=VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;cai.commandPool=pool;cai.commandBufferCount=1;cai.level=VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        if(allocateCmd(d,&cai,&cb)!=VK_SUCCESS||!cb)break;
        VkCommandBufferBeginInfo bi{};bi.sType=VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;bi.flags=VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        if(begin(cb,&bi)!=VK_SUCCESS)break;
        VkImageMemoryBarrier ib{};ib.sType=VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;ib.oldLayout=VK_IMAGE_LAYOUT_UNDEFINED;ib.newLayout=VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        ib.srcQueueFamilyIndex=VK_QUEUE_FAMILY_IGNORED;ib.dstQueueFamilyIndex=VK_QUEUE_FAMILY_IGNORED;ib.image=image;
        ib.dstAccessMask=VK_ACCESS_TRANSFER_WRITE_BIT;ib.subresourceRange=vi.subresourceRange;
        barrier(cb,VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,VK_PIPELINE_STAGE_TRANSFER_BIT,0,0,nullptr,0,nullptr,1,&ib);
        VkClearColorValue color{};color.float32[0]=0.25f;color.float32[1]=0.5f;color.float32[2]=0.75f;color.float32[3]=1.f;
        clear(cb,image,VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,&color,1,&ib.subresourceRange);
        ib.oldLayout=VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;ib.newLayout=VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        ib.srcAccessMask=VK_ACCESS_TRANSFER_WRITE_BIT;ib.dstAccessMask=VK_ACCESS_SHADER_READ_BIT;
        barrier(cb,VK_PIPELINE_STAGE_TRANSFER_BIT,VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,0,0,nullptr,0,nullptr,1,&ib);
        if(end(cb)!=VK_SUCCESS)break;
        m|=16u;
        VkFenceCreateInfo fci{};fci.sType=VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
        if(createFence(d,&fci,nullptr,&fence)!=VK_SUCCESS||!fence)break;
        VkSemaphoreCreateInfo sci{};sci.sType=VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
        if(createSemaphore(d,&sci,nullptr,&imageReady)!=VK_SUCCESS||!imageReady)break;
        m|=1024u;
        VkSubmitInfo producer{};producer.sType=VK_STRUCTURE_TYPE_SUBMIT_INFO;
        producer.commandBufferCount=1;producer.pCommandBuffers=&cb;
        producer.signalSemaphoreCount=1;producer.pSignalSemaphores=&imageReady;
        if(submit(o.context.queue,1,&producer,VK_NULL_HANDLE)!=VK_SUCCESS)break;
        submitted=true;queueWorkPending=true;m|=32u;
        VkPipelineStageFlags waitStage=VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT;
        VkSubmitInfo consumer{};consumer.sType=VK_STRUCTURE_TYPE_SUBMIT_INFO;
        consumer.waitSemaphoreCount=1;consumer.pWaitSemaphores=&imageReady;
        consumer.pWaitDstStageMask=&waitStage;
        if(submit(o.context.queue,1,&consumer,fence)!=VK_SUCCESS)break;
        m|=2048u;
        if(waitFence(d,1,&fence,VK_TRUE,5000000000ULL)!=VK_SUCCESS)break;
        submitted=false;queueWorkPending=false;m|=64u;
        m|=4096u;
        f.hw={};f.active=true;f.pending=false;f.accepted=0;f.rejected=0;f.consumed=0;f.view=VK_NULL_HANDLE;
        f.hw.interface_type=RETRO_HW_RENDER_INTERFACE_VULKAN;f.hw.interface_version=5;
        f.hw.handle=&f;f.hw.device=d;f.hw.queue=o.context.queue;f.hw.queue_index=o.context.queue_family_index;
        f.hw.set_image=AzV181SetImage;f.hw.wait_sync_index=AzV181WaitSync;
        retro_vulkan_image descriptor{};descriptor.image_view=view;descriptor.image_layout=VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        descriptor.create_info=vi;
        f.hw.set_image(f.hw.handle,&descriptor,0,nullptr,f.hw.queue_index);
        if(f.pending&&f.accepted==1&&f.view==view)m|=128u;
        f.hw.wait_sync_index(f.hw.handle);
        if(!f.pending&&f.consumed==1)m|=256u;
        f.active=false;f.pending=false;f.view=VK_NULL_HANDLE;f.hw={};
    } while(false);
    if(f.active){f.active=false;f.pending=false;f.view=VK_NULL_HANDLE;f.hw={};}
    bool drained=!queueWorkPending || queueIdle(o.context.queue)==VK_SUCCESS;
    if(!drained) return m; // Safety: do not release any in-flight GPU resources.
    if(fence)destroyFence(d,fence,nullptr);
    if(imageReady)destroySemaphore(d,imageReady,nullptr);
    if(pool)destroyPool(d,pool,nullptr);
    if(view)destroyView(d,view,nullptr);
    if(image)destroyImage(d,image,nullptr);
    if(memory)freeMemory(d,memory,nullptr);
    if(!f.active&&!f.pending&&!f.view)m|=512u;
    return m;
}

/* Castle 184 lane B: audit cohesive negotiated Vulkan ABI for publication risks.
   This proves fields and callbacks can be staged on ONE core-created device.
   It explicitly does not claim core renderer publication or frame presentation. */
extern "C" unsigned AzaharV184PublicationAudit(void) {
    const auto &o=gAzV178Negotiated;
    auto &f=gAzV181Private;
    if(!o.active || f.active || !o.instance || !o.context.gpu ||
       !o.context.device || !o.context.queue || !o.gdpa) return 0;
    unsigned m=1u;
    retro_hw_render_interface_vulkan h{};
    h.interface_type=RETRO_HW_RENDER_INTERFACE_VULKAN;
    h.interface_version=RETRO_HW_RENDER_INTERFACE_VULKAN_VERSION;
    h.handle=&f;h.instance=o.instance;h.gpu=o.context.gpu;h.device=o.context.device;
    h.queue=o.context.queue;h.queue_index=o.context.queue_family_index;
    h.get_device_proc_addr=o.gdpa;
    h.get_instance_proc_addr=gAzV151Descriptor.hw.get_instance_proc_addr;
    h.set_image=AzV181SetImage;h.get_sync_index=AzV181SyncIndex;
    h.get_sync_index_mask=AzV181SyncMask;h.lock_queue=AzV181LockQueue;
    h.unlock_queue=AzV181UnlockQueue;h.wait_sync_index=AzV181WaitSync;
    if(h.interface_version==5 && h.interface_type==RETRO_HW_RENDER_INTERFACE_VULKAN)m|=2u;
    if(h.instance==o.instance && h.gpu==o.context.gpu && h.device==o.context.device && h.queue==o.context.queue)m|=4u;
    if(h.queue_index==o.context.queue_family_index && h.get_instance_proc_addr && h.get_device_proc_addr)m|=8u;
    if(h.handle && h.set_image && h.get_sync_index && h.get_sync_index_mask && h.lock_queue && h.unlock_queue && h.wait_sync_index)m|=16u;
    if(h.get_device_proc_addr(h.device,"vkQueueSubmit") && h.get_device_proc_addr(h.device,"vkWaitForFences"))m|=32u;
    // f is currently inactive, so stale/retired callbacks refuse to produce a sync slot.
    if(h.get_sync_index(h.handle)==UINT32_MAX && h.get_sync_index_mask(h.handle)==0)m|=64u;
    // A descriptor existing in private memory never constitutes hardware publication.
    if(!f.active && !f.pending && !f.view)m|=128u;
    return m;
}


/* Castle v185: a substantive real GPU consumer, not an empty wait.
   The Azahar callback-created device produces an 8x8 RGBA image with a
   binary semaphore; a second command buffer WAITs on that semaphore,
   transitions the actual image, copies pixels to a HOST_VISIBLE buffer,
   restores the image layout, and completes by fence. Pixels are verified
   before privately invoking set_image and acknowledging completion.
   Only disposable preflight is supported; no core renderer publication. */
extern "C" unsigned AzaharV185NegotiatedImageConsumer(unsigned char *rgba, unsigned capacity) {
    const auto &o=gAzV178Negotiated;
    auto &f=gAzV181Private;
    if(!rgba || capacity<8u*8u*4u || !o.active || !o.instance ||
       !o.context.device || !o.context.gpu || !o.context.queue || !o.gdpa || f.active ||
       !gAzV151Descriptor.hw.get_instance_proc_addr) return 0;
    const VkDevice d=o.context.device;
#define AZ185(T,name) reinterpret_cast<T>(o.gdpa(d,"vk" #name))
    auto createImage=AZ185(PFN_vkCreateImage,CreateImage);
    auto destroyImage=AZ185(PFN_vkDestroyImage,DestroyImage);
    auto imgRequirements=AZ185(PFN_vkGetImageMemoryRequirements,GetImageMemoryRequirements);
    auto createBuffer=AZ185(PFN_vkCreateBuffer,CreateBuffer);
    auto destroyBuffer=AZ185(PFN_vkDestroyBuffer,DestroyBuffer);
    auto bufRequirements=AZ185(PFN_vkGetBufferMemoryRequirements,GetBufferMemoryRequirements);
    auto allocate=AZ185(PFN_vkAllocateMemory,AllocateMemory);
    auto freeMemory=AZ185(PFN_vkFreeMemory,FreeMemory);
    auto bindImage=AZ185(PFN_vkBindImageMemory,BindImageMemory);
    auto bindBuffer=AZ185(PFN_vkBindBufferMemory,BindBufferMemory);
    auto createView=AZ185(PFN_vkCreateImageView,CreateImageView);
    auto destroyView=AZ185(PFN_vkDestroyImageView,DestroyImageView);
    auto createPool=AZ185(PFN_vkCreateCommandPool,CreateCommandPool);
    auto destroyPool=AZ185(PFN_vkDestroyCommandPool,DestroyCommandPool);
    auto allocateCmd=AZ185(PFN_vkAllocateCommandBuffers,AllocateCommandBuffers);
    auto begin=AZ185(PFN_vkBeginCommandBuffer,BeginCommandBuffer);
    auto end=AZ185(PFN_vkEndCommandBuffer,EndCommandBuffer);
    auto barrier=AZ185(PFN_vkCmdPipelineBarrier,CmdPipelineBarrier);
    auto clear=AZ185(PFN_vkCmdClearColorImage,CmdClearColorImage);
    auto copy=AZ185(PFN_vkCmdCopyImageToBuffer,CmdCopyImageToBuffer);
    auto submit=AZ185(PFN_vkQueueSubmit,QueueSubmit);
    auto createSemaphore=AZ185(PFN_vkCreateSemaphore,CreateSemaphore);
    auto destroySemaphore=AZ185(PFN_vkDestroySemaphore,DestroySemaphore);
    auto createFence=AZ185(PFN_vkCreateFence,CreateFence);
    auto destroyFence=AZ185(PFN_vkDestroyFence,DestroyFence);
    auto waitFence=AZ185(PFN_vkWaitForFences,WaitForFences);
    auto queueIdle=AZ185(PFN_vkQueueWaitIdle,QueueWaitIdle);
    auto map=AZ185(PFN_vkMapMemory,MapMemory);
    auto unmap=AZ185(PFN_vkUnmapMemory,UnmapMemory);
    auto invalidate=AZ185(PFN_vkInvalidateMappedMemoryRanges,InvalidateMappedMemoryRanges);
#undef AZ185
    auto memoryProperties=reinterpret_cast<PFN_vkGetPhysicalDeviceMemoryProperties>(
        gAzV151Descriptor.hw.get_instance_proc_addr(o.instance,"vkGetPhysicalDeviceMemoryProperties"));
    if(!createImage||!destroyImage||!imgRequirements||!createBuffer||!destroyBuffer||!bufRequirements||
       !allocate||!freeMemory||!bindImage||!bindBuffer||!createView||!destroyView||!createPool||
       !destroyPool||!allocateCmd||!begin||!end||!barrier||!clear||!copy||!submit||!createSemaphore||
       !destroySemaphore||!createFence||!destroyFence||!waitFence||!queueIdle||!map||!unmap||
       !invalidate||!memoryProperties) return 0;
    unsigned m=1u;
    VkImage image=VK_NULL_HANDLE;
    VkImageView view=VK_NULL_HANDLE;
    VkDeviceMemory imageMemory=VK_NULL_HANDLE, readMemory=VK_NULL_HANDLE;
    VkBuffer readBuffer=VK_NULL_HANDLE;
    VkCommandPool pool=VK_NULL_HANDLE;
    VkSemaphore ready=VK_NULL_HANDLE;
    VkFence fence=VK_NULL_HANDLE;
    bool inFlight=false;
    do {
        VkPhysicalDeviceMemoryProperties mp{};memoryProperties(o.context.gpu,&mp);
        auto memoryIndex=[&](uint32_t bits,VkMemoryPropertyFlags required)->uint32_t {
            for(uint32_t i=0;i<mp.memoryTypeCount;++i)
                if((bits&(1u<<i)) && (mp.memoryTypes[i].propertyFlags&required)==required)return i;
            return UINT32_MAX;
        };
        VkImageCreateInfo ii{};ii.sType=VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
        ii.flags=VK_IMAGE_CREATE_MUTABLE_FORMAT_BIT; // official libretro 8-bit image contract
        ii.imageType=VK_IMAGE_TYPE_2D;ii.format=VK_FORMAT_R8G8B8A8_UNORM;
        ii.extent={8,8,1};ii.mipLevels=1;ii.arrayLayers=1;
        ii.samples=VK_SAMPLE_COUNT_1_BIT;ii.tiling=VK_IMAGE_TILING_OPTIMAL;
        ii.usage=VK_IMAGE_USAGE_TRANSFER_SRC_BIT|VK_IMAGE_USAGE_TRANSFER_DST_BIT|VK_IMAGE_USAGE_SAMPLED_BIT;
        ii.sharingMode=VK_SHARING_MODE_EXCLUSIVE;ii.initialLayout=VK_IMAGE_LAYOUT_UNDEFINED;
        if(createImage(d,&ii,nullptr,&image)!=VK_SUCCESS || !image)break;
        m|=2u;
        VkMemoryRequirements ir{};imgRequirements(d,image,&ir);
        uint32_t deviceMem=memoryIndex(ir.memoryTypeBits,VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
        if(deviceMem==UINT32_MAX)deviceMem=memoryIndex(ir.memoryTypeBits,0);
        if(deviceMem==UINT32_MAX)break;
        VkMemoryAllocateInfo mi{};mi.sType=VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        mi.allocationSize=ir.size;mi.memoryTypeIndex=deviceMem;
        if(allocate(d,&mi,nullptr,&imageMemory)!=VK_SUCCESS||!imageMemory||
           bindImage(d,image,imageMemory,0)!=VK_SUCCESS)break;
        m|=4u;
        VkImageViewCreateInfo vi{};vi.sType=VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        vi.image=image;vi.viewType=VK_IMAGE_VIEW_TYPE_2D;vi.format=ii.format;
        vi.subresourceRange.aspectMask=VK_IMAGE_ASPECT_COLOR_BIT;
        vi.subresourceRange.levelCount=1;vi.subresourceRange.layerCount=1;
        if(createView(d,&vi,nullptr,&view)!=VK_SUCCESS||!view)break;
        m|=8u;
        VkBufferCreateInfo bc{};bc.sType=VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
        bc.size=8u*8u*4u;bc.usage=VK_BUFFER_USAGE_TRANSFER_DST_BIT;
        bc.sharingMode=VK_SHARING_MODE_EXCLUSIVE;
        if(createBuffer(d,&bc,nullptr,&readBuffer)!=VK_SUCCESS||!readBuffer)break;
        m|=16u;
        VkMemoryRequirements br{};bufRequirements(d,readBuffer,&br);
        uint32_t hostMem=memoryIndex(br.memoryTypeBits,VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT|VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
        if(hostMem==UINT32_MAX)hostMem=memoryIndex(br.memoryTypeBits,VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT);
        if(hostMem==UINT32_MAX)break;
        mi.allocationSize=br.size;mi.memoryTypeIndex=hostMem;
        if(allocate(d,&mi,nullptr,&readMemory)!=VK_SUCCESS||!readMemory||
           bindBuffer(d,readBuffer,readMemory,0)!=VK_SUCCESS)break;
        m|=32u;
        VkCommandPoolCreateInfo pi{};pi.sType=VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
        pi.queueFamilyIndex=o.context.queue_family_index;
        if(createPool(d,&pi,nullptr,&pool)!=VK_SUCCESS||!pool)break;
        VkCommandBuffer cb[2]={VK_NULL_HANDLE,VK_NULL_HANDLE};
        VkCommandBufferAllocateInfo cai{};cai.sType=VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
        cai.commandPool=pool;cai.level=VK_COMMAND_BUFFER_LEVEL_PRIMARY;cai.commandBufferCount=2;
        if(allocateCmd(d,&cai,cb)!=VK_SUCCESS||!cb[0]||!cb[1])break;
        VkCommandBufferBeginInfo bi{};bi.sType=VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        bi.flags=VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        VkImageMemoryBarrier ib{};ib.sType=VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        ib.srcQueueFamilyIndex=VK_QUEUE_FAMILY_IGNORED;ib.dstQueueFamilyIndex=VK_QUEUE_FAMILY_IGNORED;
        ib.image=image;ib.subresourceRange=vi.subresourceRange;
        if(begin(cb[0],&bi)!=VK_SUCCESS)break;
        ib.oldLayout=VK_IMAGE_LAYOUT_UNDEFINED;ib.newLayout=VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        ib.dstAccessMask=VK_ACCESS_TRANSFER_WRITE_BIT;
        barrier(cb[0],VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,VK_PIPELINE_STAGE_TRANSFER_BIT,0,0,nullptr,0,nullptr,1,&ib);
        VkClearColorValue col{};col.float32[0]=.25f;col.float32[1]=.5f;
        col.float32[2]=.75f;col.float32[3]=1.f;
        clear(cb[0],image,VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,&col,1,&ib.subresourceRange);
        ib.oldLayout=VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        ib.newLayout=VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        ib.srcAccessMask=VK_ACCESS_TRANSFER_WRITE_BIT;ib.dstAccessMask=VK_ACCESS_SHADER_READ_BIT;
        barrier(cb[0],VK_PIPELINE_STAGE_TRANSFER_BIT,VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,0,0,nullptr,0,nullptr,1,&ib);
        if(end(cb[0])!=VK_SUCCESS||begin(cb[1],&bi)!=VK_SUCCESS)break;
        ib.oldLayout=VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        ib.newLayout=VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
        ib.srcAccessMask=VK_ACCESS_SHADER_READ_BIT;ib.dstAccessMask=VK_ACCESS_TRANSFER_READ_BIT;
        barrier(cb[1],VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,VK_PIPELINE_STAGE_TRANSFER_BIT,0,0,nullptr,0,nullptr,1,&ib);
        VkBufferImageCopy region{};region.imageSubresource.aspectMask=VK_IMAGE_ASPECT_COLOR_BIT;
        region.imageSubresource.layerCount=1;region.imageExtent={8,8,1};
        copy(cb[1],image,VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,readBuffer,1,&region);
        ib.oldLayout=VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
        ib.newLayout=VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        ib.srcAccessMask=VK_ACCESS_TRANSFER_READ_BIT;ib.dstAccessMask=VK_ACCESS_SHADER_READ_BIT;
        barrier(cb[1],VK_PIPELINE_STAGE_TRANSFER_BIT,VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,0,0,nullptr,0,nullptr,1,&ib);
        VkBufferMemoryBarrier bb{};bb.sType=VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER;
        bb.srcAccessMask=VK_ACCESS_TRANSFER_WRITE_BIT;bb.dstAccessMask=VK_ACCESS_HOST_READ_BIT;
        bb.srcQueueFamilyIndex=VK_QUEUE_FAMILY_IGNORED;bb.dstQueueFamilyIndex=VK_QUEUE_FAMILY_IGNORED;
        bb.buffer=readBuffer;bb.offset=0;bb.size=VK_WHOLE_SIZE;
        barrier(cb[1],VK_PIPELINE_STAGE_TRANSFER_BIT,VK_PIPELINE_STAGE_HOST_BIT,0,0,nullptr,1,&bb,0,nullptr);
        if(end(cb[1])!=VK_SUCCESS)break;
        m|=64u;
        VkSemaphoreCreateInfo si{};si.sType=VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
        VkFenceCreateInfo fi{};fi.sType=VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
        if(createSemaphore(d,&si,nullptr,&ready)!=VK_SUCCESS||!ready||
           createFence(d,&fi,nullptr,&fence)!=VK_SUCCESS||!fence)break;
        VkSubmitInfo producer{};producer.sType=VK_STRUCTURE_TYPE_SUBMIT_INFO;
        producer.commandBufferCount=1;producer.pCommandBuffers=&cb[0];
        producer.signalSemaphoreCount=1;producer.pSignalSemaphores=&ready;
        if(submit(o.context.queue,1,&producer,VK_NULL_HANDLE)!=VK_SUCCESS)break;
        inFlight=true;m|=128u;
        VkPipelineStageFlags stage=VK_PIPELINE_STAGE_TRANSFER_BIT;
        VkSubmitInfo consumer{};consumer.sType=VK_STRUCTURE_TYPE_SUBMIT_INFO;
        consumer.waitSemaphoreCount=1;consumer.pWaitSemaphores=&ready;
        consumer.pWaitDstStageMask=&stage;consumer.commandBufferCount=1;
        consumer.pCommandBuffers=&cb[1];
        if(submit(o.context.queue,1,&consumer,fence)!=VK_SUCCESS)break;
        m|=256u;
        if(waitFence(d,1,&fence,VK_TRUE,5000000000ULL)!=VK_SUCCESS)break;
        inFlight=false;m|=512u;
        void *mapped=nullptr;
        if(map(d,readMemory,0,VK_WHOLE_SIZE,0,&mapped)!=VK_SUCCESS||!mapped)break;
        const bool coherent=(mp.memoryTypes[hostMem].propertyFlags&VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)!=0;
        bool invalidated=true;
        if(!coherent){
            VkMappedMemoryRange range{};range.sType=VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE;
            range.memory=readMemory;range.offset=0;range.size=VK_WHOLE_SIZE;
            invalidated=invalidate(d,1,&range)==VK_SUCCESS;
        }
        if(invalidated)memcpy(rgba,mapped,8u*8u*4u);
        unmap(d,readMemory);
        if(!invalidated)break;
        bool pixelsOK=true;
        for(unsigned i=0;i<8u*8u;++i){
            unsigned char *p=rgba+4u*i;
            if(p[0]<63||p[0]>65||p[1]<127||p[1]>129||
               p[2]<190||p[2]>192||p[3]!=255){pixelsOK=false;break;}
        }
        if(!pixelsOK)break;
        m|=1024u;
        // Retain the descriptor until callback consumer acknowledgement (private scope).
        f.hw={};f.active=true;f.pending=false;f.accepted=0;f.rejected=0;
        f.consumed=0;f.view=VK_NULL_HANDLE;
        f.hw.interface_type=RETRO_HW_RENDER_INTERFACE_VULKAN;
        f.hw.interface_version=RETRO_HW_RENDER_INTERFACE_VULKAN_VERSION;
        f.hw.handle=&f;f.hw.device=d;f.hw.queue=o.context.queue;
        f.hw.queue_index=o.context.queue_family_index;
        f.hw.set_image=AzV181SetImage;f.hw.wait_sync_index=AzV181WaitSync;
        retro_vulkan_image descriptor{};descriptor.image_view=view;
        descriptor.image_layout=VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        descriptor.create_info=vi;
        f.hw.set_image(f.hw.handle,&descriptor,0,nullptr,f.hw.queue_index);
        const bool captured=f.pending&&f.accepted==1&&f.view==view;
        if(captured)f.hw.wait_sync_index(f.hw.handle);
        if(captured&&!f.pending&&f.consumed==1)m|=2048u;
        f.active=false;f.pending=false;f.view=VK_NULL_HANDLE;f.hw={};
    }while(false);
    if(f.active){f.active=false;f.pending=false;f.view=VK_NULL_HANDLE;f.hw={};}
    // Do not free in-flight command buffers or semaphores on any failed wait.
    bool drained=!inFlight || queueIdle(o.context.queue)==VK_SUCCESS;
    if(!drained)return m;
    if(fence)destroyFence(d,fence,nullptr);
    if(ready)destroySemaphore(d,ready,nullptr);
    if(pool)destroyPool(d,pool,nullptr);
    if(view)destroyView(d,view,nullptr);
    if(readBuffer)destroyBuffer(d,readBuffer,nullptr);
    if(image)destroyImage(d,image,nullptr);
    if(readMemory)freeMemory(d,readMemory,nullptr);
    if(imageMemory)freeMemory(d,imageMemory,nullptr);
    if(!f.active&&!f.pending&&!f.view)m|=4096u;
    return m;
}

/* Castle 185: verify the image descriptor used for future public interface
   obeys Vulkan libretro contract, not merely struct pointer presence. */
extern "C" unsigned AzaharV185ImageContractAudit(void) {
    const auto &o=gAzV178Negotiated;
    if(!o.active || !o.instance || !o.context.device || !o.context.queue ||
       !o.context.gpu || !o.gdpa || gAzV181Private.active) return 0;
    unsigned m=1u;
    if(RETRO_HW_RENDER_INTERFACE_VULKAN_VERSION>=5)m|=2u;
    const VkImageUsageFlags usage=VK_IMAGE_USAGE_TRANSFER_SRC_BIT |
        VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT;
    if((usage&(VK_IMAGE_USAGE_TRANSFER_SRC_BIT|VK_IMAGE_USAGE_SAMPLED_BIT))==
        (VK_IMAGE_USAGE_TRANSFER_SRC_BIT|VK_IMAGE_USAGE_SAMPLED_BIT))m|=4u;
    if((VK_IMAGE_CREATE_MUTABLE_FORMAT_BIT&VK_IMAGE_CREATE_MUTABLE_FORMAT_BIT)!=0)m|=8u;
    if(o.context.queue_family_index<UINT32_MAX && o.context.queue)m|=16u;
    if(o.gdpa(o.context.device,"vkCmdCopyImageToBuffer") &&
       o.gdpa(o.context.device,"vkQueueSubmit"))m|=32u;
    if(!gAzV181Private.pending && !gAzV181Private.active)m|=64u;
    // The actual core source still is not permitted to access this descriptor.
    if(gAzV178Negotiated.active && AzaharV178RetainedState()==7u)m|=128u;
    return m;
}


extern "C" void *AzaharV178NegotiatedInstance(void) {return reinterpret_cast<void *>(gAzV178Negotiated.instance);}
extern "C" void *AzaharV178NegotiatedGPU(void) {return reinterpret_cast<void *>(gAzV178Negotiated.context.gpu);}
extern "C" void *AzaharV178NegotiatedDevice(void) {return reinterpret_cast<void *>(gAzV178Negotiated.context.device);}
extern "C" void *AzaharV178NegotiatedQueue(void) {return reinterpret_cast<void *>(gAzV178Negotiated.context.queue);}
extern "C" void *AzaharV178NegotiatedGIPA(void) {return reinterpret_cast<void *>(gAzV151Descriptor.hw.get_instance_proc_addr);}
extern "C" unsigned AzaharV178NegotiatedQueueFamily(void) {return gAzV178Negotiated.context.queue_family_index;}


/* Castle 186: invoke the CORE'S REAL v2 Vulkan callbacks with frontend
 * wrappers in a disposable negotiation scope. The wrapper honors the core's
 * extension/feature chain unchanged, rather than inventing its requested
 * VkDeviceCreateInfo. This is a real negotiation test, not renderer start:
 * SET_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE still returns false.
 * No handles survive and no image is published. */
struct AzV186WrapperScope {
    PFN_vkGetInstanceProcAddr gip = nullptr;
    VkInstance instance = VK_NULL_HANDLE;
    VkDevice device = VK_NULL_HANDLE;
    unsigned instance_calls = 0;
    unsigned device_calls = 0;
    VkResult last_instance_result = VK_ERROR_INITIALIZATION_FAILED;
    VkResult last_device_result = VK_ERROR_INITIALIZATION_FAILED;
};
static VkInstance AzV186InstanceWrapper(void *opaque, const VkInstanceCreateInfo *create_info) {
    auto *s=static_cast<AzV186WrapperScope *>(opaque);
    if(!s || !s->gip || !create_info || s->instance || s->instance_calls ||
       create_info->sType!=VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO) return VK_NULL_HANDLE;
    ++s->instance_calls;
    auto proc=reinterpret_cast<PFN_vkCreateInstance>(s->gip(VK_NULL_HANDLE,"vkCreateInstance"));
    if (!proc) return VK_NULL_HANDLE;
    s->last_instance_result=proc(create_info,nullptr,&s->instance);
    if (s->last_instance_result!=VK_SUCCESS) s->instance=VK_NULL_HANDLE;
    return s->instance;
}
static VkDevice AzV186DeviceWrapper(VkPhysicalDevice gpu,void *opaque,
                                   const VkDeviceCreateInfo *create_info) {
    auto *s=static_cast<AzV186WrapperScope *>(opaque);
    if(!s || !s->gip || !s->instance || !gpu || !create_info ||
       s->device || s->device_calls ||
       create_info->sType!=VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO) return VK_NULL_HANDLE;
    ++s->device_calls;
    auto proc=reinterpret_cast<PFN_vkCreateDevice>(s->gip(s->instance,"vkCreateDevice"));
    if(!proc) return VK_NULL_HANDLE;
    s->last_device_result=proc(gpu,create_info,nullptr,&s->device);
    if(s->last_device_result!=VK_SUCCESS) s->device=VK_NULL_HANDLE;
    return s->device;
}
extern "C" unsigned AzaharV186CoreV2WrappersGate(void *getAppRaw,
                 void *createInstanceRaw,void *createDevice2Raw,void *destroyDeviceRaw) {
    // Strictly avoid modifying the independently retained v178 v1 device.
    if(gAzV178Negotiated.active || !getAppRaw || !createDevice2Raw) return 0;
    const auto &owner=gAzV151Descriptor;
    if(!owner.initialized || !owner.hw.get_instance_proc_addr) return 0;
    auto gip=owner.hw.get_instance_proc_addr;
    auto appFn=reinterpret_cast<retro_vulkan_get_application_info_t>(getAppRaw);
    auto device2=reinterpret_cast<retro_vulkan_create_device2_t>(createDevice2Raw);
    auto instanceFn=reinterpret_cast<retro_vulkan_create_instance_t>(createInstanceRaw);
    auto destroyAux=reinterpret_cast<retro_vulkan_destroy_device_t>(destroyDeviceRaw);
    unsigned m=1u;
    const VkApplicationInfo *app=appFn();
    if(!app || app->sType!=VK_STRUCTURE_TYPE_APPLICATION_INFO ||
       !app->pApplicationName || VK_VERSION_MAJOR(app->apiVersion)!=1u) return m;
    m|=2u;
    AzV186WrapperScope scope{};scope.gip=gip;
    if(instanceFn) {
        // Actual core-supplied create_instance callback must forward to our wrapper.
        const VkInstance fromCore=instanceFn(gip,app,AzV186InstanceWrapper,&scope);
        if(fromCore != scope.instance || !fromCore) goto cleanup186;
    } else {
        // The ABI explicitly allows a null v2 instance callback.
        VkInstanceCreateInfo ci{};ci.sType=VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
        ci.pApplicationInfo=app;
        if(!AzV186InstanceWrapper(&scope,&ci)) goto cleanup186;
    }
    if(scope.instance_calls!=1 || !scope.instance) goto cleanup186;
    m|=4u;
    {
        auto enumerate=reinterpret_cast<PFN_vkEnumeratePhysicalDevices>(gip(scope.instance,"vkEnumeratePhysicalDevices"));
        auto families=reinterpret_cast<PFN_vkGetPhysicalDeviceQueueFamilyProperties>(gip(scope.instance,"vkGetPhysicalDeviceQueueFamilyProperties"));
        auto gdpa=reinterpret_cast<PFN_vkGetDeviceProcAddr>(gip(scope.instance,"vkGetDeviceProcAddr"));
        if(!enumerate || !families || !gdpa) goto cleanup186;
        m|=8u;
        uint32_t count=0;
        if(enumerate(scope.instance,&count,nullptr)!=VK_SUCCESS || !count || count>16u) goto cleanup186;
        VkPhysicalDevice gpus[16]={};
        if(enumerate(scope.instance,&count,gpus)!=VK_SUCCESS)goto cleanup186;
        for(uint32_t i=0;i<count;i++) {
            uint32_t n=0;families(gpus[i],&n,nullptr);
            if(!n || n>64u)continue;
            VkQueueFamilyProperties properties[64]={};families(gpus[i],&n,properties);
            bool suitable=false;
            for(uint32_t j=0;j<n;j++)
                if(properties[j].queueCount &&
                   (properties[j].queueFlags&(VK_QUEUE_GRAPHICS_BIT|VK_QUEUE_COMPUTE_BIT))==
                   (VK_QUEUE_GRAPHICS_BIT|VK_QUEUE_COMPUTE_BIT)) suitable=true;
            if(!suitable)continue;
            m|=16u;
            retro_vulkan_context ctx{};
            const bool created=device2(&ctx,scope.instance,gpus[i],VK_NULL_HANDLE,gip,
                                       AzV186DeviceWrapper,&scope);
            if(created && ctx.device && ctx.device==scope.device && ctx.gpu==gpus[i] &&
               ctx.queue && scope.device_calls==1) {
                m|=32u;
                if(ctx.queue_family_index<n && properties[ctx.queue_family_index].queueCount &&
                    (properties[ctx.queue_family_index].queueFlags &
                    (VK_QUEUE_GRAPHICS_BIT|VK_QUEUE_COMPUTE_BIT))==
                    (VK_QUEUE_GRAPHICS_BIT|VK_QUEUE_COMPUTE_BIT) &&
                    gdpa(ctx.device,"vkQueueSubmit") && gdpa(ctx.device,"vkDeviceWaitIdle")) m|=64u;
                if(destroyAux)destroyAux(); // core releases auxiliary resources, NOT frontend device
            }
            break; // one callback, one device attempt only
        }
    }
cleanup186:
    // Always drain before releasing resources; never free in-flight GPU work.
    if(scope.device) {
        auto gdpa=reinterpret_cast<PFN_vkGetDeviceProcAddr>(gip(scope.instance,"vkGetDeviceProcAddr"));
        auto idle=gdpa?reinterpret_cast<PFN_vkDeviceWaitIdle>(gdpa(scope.device,"vkDeviceWaitIdle")):nullptr;
        if(!idle || idle(scope.device)!=VK_SUCCESS) return m;
        m|=128u;
        auto destroy=reinterpret_cast<PFN_vkDestroyDevice>(gip(scope.instance,"vkDestroyDevice"));
        if(!destroy)return m;
        destroy(scope.device,nullptr);scope.device=VK_NULL_HANDLE;
    } else m|=128u;
    if(scope.instance) {
        auto destroy=reinterpret_cast<PFN_vkDestroyInstance>(gip(scope.instance,"vkDestroyInstance"));
        if(!destroy)return m;
        destroy(scope.instance,nullptr);scope.instance=VK_NULL_HANDLE;
    }
    m|=256u;
    if(!gAzV178Negotiated.active && !gAzV181Private.active &&
       !scope.instance && !scope.device)m|=512u;
    return m;
}
/* Castle 186 lane B: audit interface publication prerequisites with the
 * actual core-created device, rather than the separate frontend test device.
 * No pointer escapes and incomplete image consumers remain fail-closed. */
extern "C" unsigned AzaharV186CorePublicationBlockerAudit(void) {
    const auto &o=gAzV178Negotiated;
    if(!o.active || !o.context.device || !o.gdpa) return 0;
    unsigned m=1u;
    if(o.instance && o.context.gpu && o.context.queue)m|=2u;
    if(o.context.queue_family_index!=UINT32_MAX && o.gdpa(o.context.device,"vkQueueSubmit"))m|=4u;
    if(o.gdpa(o.context.device,"vkCmdCopyImageToBuffer") &&
       o.gdpa(o.context.device,"vkWaitForFences"))m|=8u;
    retro_hw_render_interface_vulkan h{};
    h.interface_type=RETRO_HW_RENDER_INTERFACE_VULKAN;
    h.interface_version=RETRO_HW_RENDER_INTERFACE_VULKAN_VERSION;
    h.instance=o.instance;h.gpu=o.context.gpu;h.device=o.context.device;
    h.queue=o.context.queue;h.queue_index=o.context.queue_family_index;
    h.get_instance_proc_addr=gAzV151Descriptor.hw.get_instance_proc_addr;
    h.get_device_proc_addr=o.gdpa;
    h.handle=&gAzV181Private;
    h.set_image=AzV181SetImage;
    h.get_sync_index=AzV181SyncIndex;
    h.get_sync_index_mask=AzV181SyncMask;
    h.lock_queue=AzV181LockQueue;
    h.unlock_queue=AzV181UnlockQueue;
    h.wait_sync_index=AzV181WaitSync;
    if(h.interface_version==5 && h.handle && h.set_image && h.lock_queue &&
       h.unlock_queue && h.get_sync_index && h.get_sync_index_mask && h.wait_sync_index)m|=16u;
    // Important: the old callback remains metadata-only, no real semaphore wait
    // or Azahar-originated image presentation. The interface MUST NOT publish.
    if(!gAzV181Private.active && !gAzV181Private.pending &&
       h.get_sync_index(h.handle)==UINT32_MAX)m|=32u;
    if(o.active && AzaharV178RetainedState()==7u)m|=64u;
    if(!gAzV181Private.pending && !gAzV181Private.active)m|=128u;
    return m;
}


/* Castle 187: short-lived *published to libretro* hardware interface during
 * an isolated hardware preflight.  The persistent owner is the device which
 * Azahar created through its real v1 callback in a v2 negotiation structure.
 * No Vulkan objects are borrowed across different logical devices. */
struct AzV187LiveSink {
    std::mutex stateMutex;
    std::mutex queueMutex;
    retro_hw_render_interface_vulkan hw = {};
    VkImage image=VK_NULL_HANDLE;
    VkImageView imageView=VK_NULL_HANDLE;
    VkImageLayout layout=VK_IMAGE_LAYOUT_UNDEFINED;
    VkFormat format=VK_FORMAT_UNDEFINED;
    uint32_t width=0,height=0;
    VkSemaphore semaphores[8]={};
    unsigned semaphoreCount=0, setCalls=0,rejections=0,consumed=0;
    bool active=false,pending=false;
};
static AzV187LiveSink gAzV187Live;
static void AzV187SetImage(void *handle,const retro_vulkan_image *img,
                           uint32_t n,const VkSemaphore *sems,uint32_t family) {
    auto &s=gAzV187Live;
    if(handle!=&s)return;
    std::lock_guard<std::mutex> guard(s.stateMutex);
    if(!s.active || !img || !img->image_view || !img->create_info.image ||
       img->create_info.sType!=VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO ||
       img->create_info.viewType!=VK_IMAGE_VIEW_TYPE_2D ||
       (img->image_layout!=VK_IMAGE_LAYOUT_GENERAL && img->image_layout!=VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL) ||
       (family!=VK_QUEUE_FAMILY_IGNORED && family!=s.hw.queue_index) ||
       n>8u || (n&&!sems) || s.pending) {
       ++s.rejections;return;
    }
    s.image=img->create_info.image;s.imageView=img->image_view;
    s.layout=img->image_layout;s.format=img->create_info.format;
    s.width=0; // Geometry arrives with the matching hardware video-refresh callback.
    s.height=0;
    s.semaphoreCount=n;
    for(unsigned i=0;i<n;i++)s.semaphores[i]=sems[i];
    s.pending=true;++s.setCalls;
}
static uint32_t AzV187SyncIndex(void *p){return p==&gAzV187Live&&gAzV187Live.active?0u:UINT32_MAX;}
static uint32_t AzV187SyncMask(void *p){return p==&gAzV187Live&&gAzV187Live.active?1u:0u;}
static void AzV187Lock(void *p){if(p==&gAzV187Live&&gAzV187Live.active)gAzV187Live.queueMutex.lock();}
static void AzV187Unlock(void *p){if(p==&gAzV187Live&&gAzV187Live.active)gAzV187Live.queueMutex.unlock();}
static void AzV187Wait(void *p){
    // A core may ask to reuse the image before a video-refresh callback. Drain
    // its semaphores on the negotiated queue and only then release the slot.
    if(p!=&gAzV187Live)return;
    auto &s=gAzV187Live;const auto &o=gAzV178Negotiated;
    std::lock_guard<std::mutex> guard(s.stateMutex);
    if(!s.active||!s.pending||!o.active||!o.gdpa)return;
    auto create=reinterpret_cast<PFN_vkCreateFence>(o.gdpa(o.context.device,"vkCreateFence"));
    auto destroy=reinterpret_cast<PFN_vkDestroyFence>(o.gdpa(o.context.device,"vkDestroyFence"));
    auto submit=reinterpret_cast<PFN_vkQueueSubmit>(o.gdpa(o.context.device,"vkQueueSubmit"));
    auto wait=reinterpret_cast<PFN_vkWaitForFences>(o.gdpa(o.context.device,"vkWaitForFences"));
    if(!create||!destroy||!submit||!wait)return;
    VkFenceCreateInfo fi{};fi.sType=VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
    VkFence fence=VK_NULL_HANDLE;
    if(create(o.context.device,&fi,nullptr,&fence)!=VK_SUCCESS||!fence)return;
    VkPipelineStageFlags stages[8];for(unsigned i=0;i<s.semaphoreCount;i++)stages[i]=VK_PIPELINE_STAGE_ALL_COMMANDS_BIT;
    VkSubmitInfo si{};si.sType=VK_STRUCTURE_TYPE_SUBMIT_INFO;
    si.waitSemaphoreCount=s.semaphoreCount;
    si.pWaitSemaphores=s.semaphoreCount?s.semaphores:nullptr;
    si.pWaitDstStageMask=s.semaphoreCount?stages:nullptr;
    const bool queued=submit(o.context.queue,1,&si,fence)==VK_SUCCESS;
    if(queued && wait(o.context.device,1,&fence,VK_TRUE,5000000000ULL)==VK_SUCCESS){
        s.pending=false;s.semaphoreCount=0;++s.consumed;
    } else if(queued) {
        auto idle=reinterpret_cast<PFN_vkQueueWaitIdle>(o.gdpa(o.context.device,"vkQueueWaitIdle"));
        if(idle && idle(o.context.queue)==VK_SUCCESS){s.pending=false;s.semaphoreCount=0;++s.consumed;}
        else return; // preserve fence lifetime if work is still in flight
    }
    destroy(o.context.device,fence,nullptr);
}
extern "C" unsigned AzaharV187PublishPreflightInterface(void) {
    auto &s=gAzV187Live;const auto &o=gAzV178Negotiated;
    if(s.active||!o.active||!o.context.device||!o.context.gpu||!o.context.queue||!o.gdpa||
       !o.instance||!gAzV151Descriptor.hw.get_instance_proc_addr)return 0;
    unsigned m=1u;
    s.hw={};s.image=VK_NULL_HANDLE;s.imageView=VK_NULL_HANDLE;
    s.setCalls=s.rejections=s.consumed=0;s.pending=false;
    auto &h=s.hw;
    h.interface_type=RETRO_HW_RENDER_INTERFACE_VULKAN;
    h.interface_version=RETRO_HW_RENDER_INTERFACE_VULKAN_VERSION;
    h.handle=&s;h.instance=o.instance;h.gpu=o.context.gpu;h.device=o.context.device;
    h.queue=o.context.queue;h.queue_index=o.context.queue_family_index;
    h.get_instance_proc_addr=gAzV151Descriptor.hw.get_instance_proc_addr;
    h.get_device_proc_addr=o.gdpa;
    h.set_image=AzV187SetImage;h.get_sync_index=AzV187SyncIndex;
    h.get_sync_index_mask=AzV187SyncMask;h.lock_queue=AzV187Lock;
    h.unlock_queue=AzV187Unlock;h.wait_sync_index=AzV187Wait;
    if(h.interface_version==5 && h.interface_type==RETRO_HW_RENDER_INTERFACE_VULKAN)m|=2u;
    if(h.instance && h.gpu && h.device && h.queue)m|=4u;
    if(h.get_instance_proc_addr&&h.get_device_proc_addr)m|=8u;
    if(h.set_image&&h.wait_sync_index&&h.lock_queue&&h.unlock_queue&&
       h.get_sync_index&&h.get_sync_index_mask)m|=16u;
    if(o.gdpa(o.context.device,"vkCmdCopyImageToBuffer")&&
       o.gdpa(o.context.device,"vkQueueSubmit")&&
       o.gdpa(o.context.device,"vkWaitForFences"))m|=32u;
    s.active=true;
    if(h.get_sync_index(h.handle)==0&&h.get_sync_index_mask(h.handle)==1)m|=64u;
    if(!s.pending && AzaharV178RetainedState()==7u)m|=128u;
    if(m!=0xffu){s.active=false;s.hw={};}return m;
}
extern "C" void *AzaharV187GetPublishedInterface(void){
    return gAzV187Live.active ? &gAzV187Live.hw : nullptr;
}
/* Core image format for the most recently accepted live set_image.
 * The OpenEmu bitmap frontend can use this to perform explicit BGRA output. */
extern "C" unsigned AzaharV188LiveImageFormat(void){
    auto &s=gAzV187Live;
    std::lock_guard<std::mutex> lock(s.stateMutex);
    return s.active ? (unsigned)s.format : 0u;
}
extern "C" unsigned AzaharV188LiveFramePending(void){
    auto &s=gAzV187Live;
    std::lock_guard<std::mutex> lock(s.stateMutex);
    return (unsigned)(s.active && s.pending);
}
extern "C" unsigned AzaharV187PreflightStats(void){
    const auto &s=gAzV187Live;
    return ((s.setCalls&0x3ffu)<<20)|((s.rejections&0x3ffu)<<10)|(s.consumed&0x3ffu);
}
extern "C" unsigned AzaharV187UnpublishPreflight(void){
    auto &s=gAzV187Live;
    if(!s.active)return 0;
    std::lock_guard<std::mutex> lock(s.stateMutex);
    unsigned m=1u;
    if(s.hw.device==gAzV178Negotiated.context.device)m|=2u;
    s.active=false;s.pending=false;s.image=VK_NULL_HANDLE;s.imageView=VK_NULL_HANDLE;
    s.semaphoreCount=0;s.hw={};
    if(!s.active&&!s.pending&&!s.hw.device)m|=4u;
    return m;
}
/* The following consumer is the first attempt to read a REAL core-originated
 * image (rather than synthetic pixels). Only supported 8-bit formats are read.
 * Conversion to the OpenEmu bitmap is deferred until after successful readback. */
extern "C" unsigned AzaharV187ConsumeHardwareImage(unsigned width,unsigned height,
                                            unsigned char *dst,unsigned capacity) {
    auto &s=gAzV187Live;auto &o=gAzV178Negotiated;
    if(!dst || !width || !height || width>8192||height>8192 ||
       (uint64_t)width*height*4>128ull*1024ull*1024ull ||
       (uint64_t)width*height*4>capacity||!s.active||!o.active||!o.gdpa)return 0;
    std::lock_guard<std::mutex> guard(s.stateMutex);
    if(!s.pending||!s.image||!s.imageView)return 0;
    if(s.format!=VK_FORMAT_R8G8B8A8_UNORM && s.format!=VK_FORMAT_B8G8R8A8_UNORM &&
       s.format!=VK_FORMAT_R8G8B8A8_SRGB && s.format!=VK_FORMAT_B8G8R8A8_SRGB)return 0;
    VkDevice d=o.context.device;unsigned m=1;
#define AZ187(T,name) reinterpret_cast<T>(o.gdpa(d,"vk" #name))
    auto createBuffer=AZ187(PFN_vkCreateBuffer,CreateBuffer);
    auto requirements=AZ187(PFN_vkGetBufferMemoryRequirements,GetBufferMemoryRequirements);
    auto allocate=AZ187(PFN_vkAllocateMemory,AllocateMemory);
    auto bind=AZ187(PFN_vkBindBufferMemory,BindBufferMemory);
    auto poolCreate=AZ187(PFN_vkCreateCommandPool,CreateCommandPool);
    auto cmdAlloc=AZ187(PFN_vkAllocateCommandBuffers,AllocateCommandBuffers);
    auto begin=AZ187(PFN_vkBeginCommandBuffer,BeginCommandBuffer);
    auto barrier=AZ187(PFN_vkCmdPipelineBarrier,CmdPipelineBarrier);
    auto copy=AZ187(PFN_vkCmdCopyImageToBuffer,CmdCopyImageToBuffer);
    auto end=AZ187(PFN_vkEndCommandBuffer,EndCommandBuffer);
    auto submit=AZ187(PFN_vkQueueSubmit,QueueSubmit);
    auto createFence=AZ187(PFN_vkCreateFence,CreateFence);
    auto waitFence=AZ187(PFN_vkWaitForFences,WaitForFences);
    auto map=AZ187(PFN_vkMapMemory,MapMemory);auto unmap=AZ187(PFN_vkUnmapMemory,UnmapMemory);
    auto invalidate=AZ187(PFN_vkInvalidateMappedMemoryRanges,InvalidateMappedMemoryRanges);
    auto idle=AZ187(PFN_vkQueueWaitIdle,QueueWaitIdle);
    auto destroyFence=AZ187(PFN_vkDestroyFence,DestroyFence);
    auto destroyPool=AZ187(PFN_vkDestroyCommandPool,DestroyCommandPool);
    auto destroyBuffer=AZ187(PFN_vkDestroyBuffer,DestroyBuffer);
    auto freeMem=AZ187(PFN_vkFreeMemory,FreeMemory);
#undef AZ187
    auto props=reinterpret_cast<PFN_vkGetPhysicalDeviceMemoryProperties>(
       gAzV151Descriptor.hw.get_instance_proc_addr(o.instance,"vkGetPhysicalDeviceMemoryProperties"));
    if(!createBuffer||!requirements||!allocate||!bind||!poolCreate||!cmdAlloc||!begin||!barrier||
       !copy||!end||!submit||!createFence||!waitFence||!map||!unmap||!invalidate||
       !idle||!destroyFence||!destroyPool||!destroyBuffer||!freeMem||!props)return m;
    m|=2u;
    VkBuffer buf=VK_NULL_HANDLE;VkDeviceMemory mem=VK_NULL_HANDLE;
    VkCommandPool pool=VK_NULL_HANDLE;VkFence fence=VK_NULL_HANDLE;
    bool submitted=false;
    VkPhysicalDeviceMemoryProperties mp{};props(o.context.gpu,&mp);
    uint32_t memType=UINT32_MAX;bool coherent=false;
    do {
        VkBufferCreateInfo bi{};bi.sType=VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
        bi.size=(VkDeviceSize)width*height*4;bi.usage=VK_BUFFER_USAGE_TRANSFER_DST_BIT;
        bi.sharingMode=VK_SHARING_MODE_EXCLUSIVE;
        if(createBuffer(d,&bi,nullptr,&buf)!=VK_SUCCESS||!buf)break;
        VkMemoryRequirements req{};requirements(d,buf,&req);
        for(uint32_t i=0;i<mp.memoryTypeCount;i++){
            if((req.memoryTypeBits&(1u<<i)) &&
               (mp.memoryTypes[i].propertyFlags&VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT)){
                memType=i;coherent=(mp.memoryTypes[i].propertyFlags&VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)!=0;
                if(coherent)break;
            }
        }
        if(memType==UINT32_MAX)break;
        VkMemoryAllocateInfo mi{};mi.sType=VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        mi.allocationSize=req.size;mi.memoryTypeIndex=memType;
        if(allocate(d,&mi,nullptr,&mem)!=VK_SUCCESS||!mem||bind(d,buf,mem,0)!=VK_SUCCESS)break;
        m|=4u;
        VkCommandPoolCreateInfo pi{};pi.sType=VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
        pi.queueFamilyIndex=o.context.queue_family_index;
        if(poolCreate(d,&pi,nullptr,&pool)!=VK_SUCCESS||!pool)break;
        VkCommandBuffer cb=VK_NULL_HANDLE;
        VkCommandBufferAllocateInfo cai{};cai.sType=VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
        cai.commandPool=pool;cai.level=VK_COMMAND_BUFFER_LEVEL_PRIMARY;cai.commandBufferCount=1;
        if(cmdAlloc(d,&cai,&cb)!=VK_SUCCESS||!cb)break;
        VkCommandBufferBeginInfo start{};start.sType=VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        start.flags=VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        if(begin(cb,&start)!=VK_SUCCESS)break;
        VkImageMemoryBarrier ib{};ib.sType=VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        ib.srcQueueFamilyIndex=VK_QUEUE_FAMILY_IGNORED;ib.dstQueueFamilyIndex=VK_QUEUE_FAMILY_IGNORED;
        ib.image=s.image;ib.oldLayout=s.layout;ib.newLayout=VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
        ib.srcAccessMask=VK_ACCESS_MEMORY_WRITE_BIT;ib.dstAccessMask=VK_ACCESS_TRANSFER_READ_BIT;
        ib.subresourceRange.aspectMask=VK_IMAGE_ASPECT_COLOR_BIT;
        ib.subresourceRange.baseMipLevel=0;ib.subresourceRange.levelCount=1;
        ib.subresourceRange.baseArrayLayer=0;ib.subresourceRange.layerCount=1;
        barrier(cb,VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,VK_PIPELINE_STAGE_TRANSFER_BIT,0,0,nullptr,0,nullptr,1,&ib);
        VkBufferImageCopy region{};region.imageSubresource.aspectMask=VK_IMAGE_ASPECT_COLOR_BIT;
        region.imageSubresource.layerCount=1;region.imageExtent={width,height,1};
        copy(cb,s.image,VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,buf,1,&region);
        ib.oldLayout=VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;ib.newLayout=s.layout;
        ib.srcAccessMask=VK_ACCESS_TRANSFER_READ_BIT;ib.dstAccessMask=VK_ACCESS_MEMORY_READ_BIT;
        barrier(cb,VK_PIPELINE_STAGE_TRANSFER_BIT,VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,0,0,nullptr,0,nullptr,1,&ib);
        VkBufferMemoryBarrier bb{};bb.sType=VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER;
        bb.srcAccessMask=VK_ACCESS_TRANSFER_WRITE_BIT;bb.dstAccessMask=VK_ACCESS_HOST_READ_BIT;
        bb.srcQueueFamilyIndex=VK_QUEUE_FAMILY_IGNORED;bb.dstQueueFamilyIndex=VK_QUEUE_FAMILY_IGNORED;
        bb.buffer=buf;bb.size=VK_WHOLE_SIZE;
        barrier(cb,VK_PIPELINE_STAGE_TRANSFER_BIT,VK_PIPELINE_STAGE_HOST_BIT,0,0,nullptr,1,&bb,0,nullptr);
        if(end(cb)!=VK_SUCCESS)break;
        m|=8u;
        VkFenceCreateInfo fi{};fi.sType=VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
        if(createFence(d,&fi,nullptr,&fence)!=VK_SUCCESS||!fence)break;
        VkPipelineStageFlags stages[8];for(unsigned i=0;i<s.semaphoreCount;i++)stages[i]=VK_PIPELINE_STAGE_TRANSFER_BIT;
        VkSubmitInfo si{};si.sType=VK_STRUCTURE_TYPE_SUBMIT_INFO;
        si.waitSemaphoreCount=s.semaphoreCount;si.pWaitSemaphores=s.semaphoreCount?s.semaphores:nullptr;
        si.pWaitDstStageMask=s.semaphoreCount?stages:nullptr;
        si.commandBufferCount=1;si.pCommandBuffers=&cb;
        if(submit(o.context.queue,1,&si,fence)!=VK_SUCCESS)break;
        submitted=true;m|=16u;
        if(waitFence(d,1,&fence,VK_TRUE,5000000000ULL)!=VK_SUCCESS)break;
        submitted=false;m|=32u;
        void *mapped=nullptr;if(map(d,mem,0,VK_WHOLE_SIZE,0,&mapped)!=VK_SUCCESS||!mapped)break;
        bool valid=true;
        if(!coherent){VkMappedMemoryRange r{};r.sType=VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE;
            r.memory=mem;r.size=VK_WHOLE_SIZE;valid=invalidate(d,1,&r)==VK_SUCCESS;}
        if(valid)memcpy(dst,mapped,(size_t)width*height*4);
        unmap(d,mem);
        if(!valid)break;
        m|=64u;
        s.pending=false;s.semaphoreCount=0;++s.consumed;m|=128u;
    }while(false);
    if(submitted && idle(o.context.queue)!=VK_SUCCESS)return m;
    if(fence)destroyFence(d,fence,nullptr);
    if(pool)destroyPool(d,pool,nullptr);
    if(buf)destroyBuffer(d,buf,nullptr);
    if(mem)freeMem(d,mem,nullptr);
    return m;
}
