/*
 * Host-only syntax-check stand-in for the iOS/macOS IOKit headers.
 * It declares exactly the symbols the ported DRM client and gl_test use;
 * it is not a usable IOKit implementation and is not installed anywhere.
 */
#ifndef HAKIOS_CHECK_IOKITLIB_H
#define HAKIOS_CHECK_IOKITLIB_H

#include <stddef.h>
#include <stdint.h>

typedef uint32_t io_service_t;
typedef uint32_t io_connect_t;
typedef uint32_t mach_port_t;
typedef int kern_return_t;
typedef uint64_t mach_vm_address_t;
typedef uint64_t mach_vm_size_t;

#define KERN_SUCCESS            0
#define kIOReturnSuccess        0
#define kIOReturnNoMemory       0x2d0
#define kIOReturnBadArgument    0x2c0
#define kIOReturnTimeout        0x2d6
#define kIOReturnBusy           0x2d5
#define kIOReturnNotFound       0x2c4
#define kIOReturnUnsupported    0x2c7
#define kIOMapAnywhere          0x00000001u

mach_port_t mach_task_self(void);
io_service_t IOServiceGetMatchingService(mach_port_t mainPort, void *matching);
void *IOServiceMatching(const char *name);
kern_return_t IOObjectRelease(io_service_t object);
kern_return_t IOServiceOpen(io_service_t service, mach_port_t owningTask,
    uint32_t type, io_connect_t *connection);
kern_return_t IOConnectCallStructMethod(io_connect_t connection, uint32_t selector,
    const void *inputStruct, size_t inputStructCnt, void *outputStruct,
    size_t *outputStructCnt);
kern_return_t IOConnectMapMemory64(io_connect_t connection, uint32_t memoryType,
    mach_port_t intoTask, mach_vm_address_t *address, mach_vm_size_t *size,
    uint32_t options);
kern_return_t IOConnectUnmapMemory64(io_connect_t connection, uint32_t memoryType,
    mach_port_t fromTask, mach_vm_address_t address);

#define IOCPARM_LEN(x) 0u

#endif
