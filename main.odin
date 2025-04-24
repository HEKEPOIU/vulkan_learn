package main

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:math/linalg"
import "core:mem"
import "core:os"
import "core:strings"
import "vendor:glfw"
import vk "vendor:vulkan"


WIDTH :: 800
HIGHT :: 600
MAX_FRAME_IN_FLIGHT :: 2
VERT_SHADER_PATH :: #config(VERT_SHADER_PATH, "../shader/vert.sprv")
FRAGMENT_SHADER_PATH :: #config(FRAGMENT_SHADER_PATH, "../shader/frag.sprv")

Input_Vertices: []Vertex = {
	{{-0.5, -0.5}, {1.0, 0.0, 0.0}},
	{{0.5, -0.5}, {0.0, 1.0, 0.0}},
	{{0.5, 0.5}, {0.0, 0.0, 1.0}},
	{{-0.5, 0.5}, {1.0, 1.0, 1.0}},
}
Input_Vertice_Indices: []u16 = {0, 1, 2, 2, 3, 0}

when ODIN_DEBUG {
	Debug_Validaion_Layers :: []cstring{"VK_LAYER_KHRONOS_validation"}
	debug_logger: log.Logger

	check_validation_layer_support :: proc() -> bool {
		layer_count: u32
		vk.EnumerateInstanceLayerProperties(&layer_count, nil)
		available_layer := make([dynamic]vk.LayerProperties, layer_count, context.temp_allocator)
		defer delete(available_layer)

		vk.EnumerateInstanceLayerProperties(&layer_count, raw_data(available_layer))

		for &target in Debug_Validaion_Layers {
			layer_found := false
			for &available in available_layer {
				if target == cstring(&available.layerName[0]) {
					layer_found = true
					break
				}
			}
			if !layer_found {
				return false
			}
		}


		return true
	}

	default_debug_callback :: proc "system" (
		message_severity: vk.DebugUtilsMessageSeverityFlagsEXT, // -> Set the calling convention
		message_types: vk.DebugUtilsMessageTypeFlagsEXT,
		p_callback_data: ^vk.DebugUtilsMessengerCallbackDataEXT,
		p_user_data: rawptr,
	) -> b32 {
		context = runtime.default_context()
		context.logger = debug_logger
		if (message_severity & {.WARNING}) != nil {
			log.warnf("[%v]\n%s\n", message_types, p_callback_data.pMessage)
		} else if (message_severity & {.ERROR}) != nil {
			log.errorf("[%v]\n%s\n", message_types, p_callback_data.pMessage)
		} else if (message_severity & {.VERBOSE}) != nil {
			log.infof("[%v]\n%s\n", message_types, p_callback_data.pMessage)
		}

		return false
	}


	populate_debug_messenger_create_info :: proc(info: ^vk.DebugUtilsMessengerCreateInfoEXT) {
		info.sType = vk.StructureType.DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT
		info.messageSeverity = {.ERROR, .VERBOSE, .WARNING}
		info.messageType = {.GENERAL, .VALIDATION, .PERFORMANCE}
		info.pfnUserCallback = default_debug_callback
		info.pUserData = nil
	}

	setup_debug_messenger :: proc(ctx: ^VkContext) -> IsError {
		info: vk.DebugUtilsMessengerCreateInfoEXT
		populate_debug_messenger_create_info(&info)
		if vk.CreateDebugUtilsMessengerEXT(ctx.instance, &info, nil, &ctx.debug_messenger) !=
		   .SUCCESS {
			return true
		}
		log.info("Debug Messenger Setup Success")
		return false
	}
}

when ODIN_OS == .Darwin {
	Device_Extensions: []cstring : {vk.KHR_SWAPCHAIN_EXTENSION_NAME, "VK_KHR_portability_subset"}

} else {
	Device_Extensions: []cstring : {vk.KHR_SWAPCHAIN_EXTENSION_NAME}
}
IsError :: bool

VkContext :: struct {
	instance:                 vk.Instance,
	debug_messenger:          vk.DebugUtilsMessengerEXT,
	physical_device:          vk.PhysicalDevice,
	device:                   vk.Device,
	graphic_queue:            vk.Queue,
	present_queue:            vk.Queue,
	render_pass:              vk.RenderPass,
	pipeline_layout:          vk.PipelineLayout,
	graphic_pipeline:         vk.Pipeline,
	command_pool:             vk.CommandPool,
	command_buffers:          [dynamic]vk.CommandBuffer,
	image_available_sems:     [dynamic]vk.Semaphore,
	render_finish_sems:       [dynamic]vk.Semaphore,
	in_flight_fences:         [dynamic]vk.Fence,
	current_frame:            u32,
	frame_buffer_resized:     bool,
	vertex_buffer:            vk.Buffer,
	vertex_buffer_memory:     vk.DeviceMemory,
	index_buffer:             vk.Buffer,
	index_buffer_memory:      vk.DeviceMemory,

	//-- Only need on windows render.
	surface:                  vk.SurfaceKHR,
	swap_chain:               vk.SwapchainKHR,
	swap_chain_image:         [dynamic]vk.Image,
	swap_chain_image_view:    [dynamic]vk.ImageView,
	swap_chain_frame_buffers: [dynamic]vk.Framebuffer,
	swap_chain_image_format:  vk.Format,
	swap_chain_extent:        vk.Extent2D,
	//--
}

Vertex :: struct {
	pos:   linalg.Vector2f32,
	color: linalg.Vector3f32,
}

get_binding_description :: proc() -> vk.VertexInputBindingDescription {
	binding_description: vk.VertexInputBindingDescription = {
		binding   = 0,
		stride    = size_of(Vertex),
		inputRate = .VERTEX,
	}
	return binding_description
}
get_attribute_description :: proc() -> [2]vk.VertexInputAttributeDescription {
	attribute_descs: [2]vk.VertexInputAttributeDescription
	attribute_descs[0].binding = 0
	attribute_descs[0].location = 0 // from vert.glsl in layout 0
	attribute_descs[0].format = .R32G32_SFLOAT
	attribute_descs[0].offset = (u32)(offset_of(Vertex, pos))

	attribute_descs[1].binding = 0
	attribute_descs[1].location = 1 // from vert.glsl in layout 0
	attribute_descs[1].format = .R32G32B32_SFLOAT
	attribute_descs[1].offset = (u32)(offset_of(Vertex, color))


	return attribute_descs
}

QueueFamilyIndices :: struct {
	graphics_family: Maybe(u32),
	present_fanmily: Maybe(u32),
}

create_buffer :: proc(
	using ctx: ^VkContext,
	size: vk.DeviceSize,
	usage: vk.BufferUsageFlags,
	properties: vk.MemoryPropertyFlags,
	buffer: ^vk.Buffer,
	buffer_memory: ^vk.DeviceMemory,
) -> IsError {
	buffer_info: vk.BufferCreateInfo = {
		sType       = .BUFFER_CREATE_INFO,
		size        = size,
		usage       = usage,
		sharingMode = .EXCLUSIVE,
		flags       = {},
	}
	if vk.CreateBuffer(device, &buffer_info, nil, buffer) != .SUCCESS {
		log.error("Failed to create vertex buffer")
		return true
	}
	mem_requirement: vk.MemoryRequirements
	vk.GetBufferMemoryRequirements(device, buffer^, &mem_requirement)
	type_index := find_memory_type(ctx, mem_requirement.memoryTypeBits, properties)
	if type_index == nil {
		log.error("Can't find suitable memory type index")
		return true
	}
	alloc_info: vk.MemoryAllocateInfo = {
		sType           = .MEMORY_ALLOCATE_INFO,
		allocationSize  = mem_requirement.size,
		memoryTypeIndex = type_index.(u32),
	}
	if vk.AllocateMemory(device, &alloc_info, nil, buffer_memory) != .SUCCESS {
		log.error("Allocate buffer memory Failed")
		return true
	}

	vk.BindBufferMemory(device, buffer^, buffer_memory^, 0)
	return false
}

copy_buffer :: proc(
	using ctx: ^VkContext,
	src: vk.Buffer,
	dst: vk.Buffer,
	size: vk.DeviceSize,
) -> IsError {
	alloc_info: vk.CommandBufferAllocateInfo = {
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		level              = .PRIMARY,
		commandPool        = command_pool,
		commandBufferCount = 1,
	}
	command_buffer: vk.CommandBuffer
	if vk.AllocateCommandBuffers(device, &alloc_info, &command_buffer) != .SUCCESS {
		log.error("failed to allocate command buffer")
		return true
	}

	begin_info: vk.CommandBufferBeginInfo = {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT},
	}
	if vk.BeginCommandBuffer(command_buffer, &begin_info) != .SUCCESS {
		log.error("failed to Begin command buffer")
		return true
	}

	copy_region: vk.BufferCopy = {
		srcOffset = 0,
		dstOffset = 0,
		size      = size,
	}
	vk.CmdCopyBuffer(command_buffer, src, dst, 1, &copy_region)
	if vk.EndCommandBuffer(command_buffer) != .SUCCESS {
		log.error("Failed to end command buffer")
		return true
	}
	submit_info: vk.SubmitInfo = {
		sType              = .SUBMIT_INFO,
		commandBufferCount = 1,
		pCommandBuffers    = &command_buffer,
	}
	if vk.QueueSubmit(graphic_queue, 1, &submit_info, 0) != .SUCCESS {
		log.error("Failed to submit cmd to queue")
		return true
	}
	if vk.QueueWaitIdle(graphic_queue) != .SUCCESS {
		log.error("Wait copy finish failed")
		return true
	}
	vk.FreeCommandBuffers(device, command_pool, 1, &command_buffer)
	return false
}

create_vertex_buffer :: proc(using ctx: ^VkContext) -> IsError {
	buffer_size := vk.DeviceSize(size_of(Input_Vertices[0]) * len(Input_Vertices))
	staging_buffer: vk.Buffer
	staging_buffer_memory: vk.DeviceMemory
	result := create_buffer(
		ctx,
		buffer_size,
		{.TRANSFER_SRC},
		{.HOST_VISIBLE, .HOST_COHERENT},
		&staging_buffer,
		&staging_buffer_memory,
	)
	if result {
		log.error("Faild to create staging buffer")
		return true
	}
	data: rawptr
	vk.MapMemory(device, staging_buffer_memory, 0, buffer_size, {}, &data)
	mem.copy(data, &Input_Vertices[0], int(buffer_size))
	vk.UnmapMemory(device, staging_buffer_memory)

	result = create_buffer(
		ctx,
		buffer_size,
		{.VERTEX_BUFFER, .TRANSFER_DST},
		{.DEVICE_LOCAL},
		&vertex_buffer,
		&vertex_buffer_memory,
	)
	if result {
		log.error("Faild to create vertex buffer")
		return true
	}

	copy_buffer(ctx, staging_buffer, vertex_buffer, buffer_size)

	vk.DestroyBuffer(device, staging_buffer, nil)
	vk.FreeMemory(device, staging_buffer_memory, nil)


	log.info("Success create vertex buffer")
	return false
}

create_index_buffer :: proc(using ctx: ^VkContext) -> IsError {
	buffer_size := vk.DeviceSize(size_of(Input_Vertice_Indices[0]) * len(Input_Vertice_Indices))
	staging_buffer: vk.Buffer
	staging_buffer_memory: vk.DeviceMemory
	result := create_buffer(
		ctx,
		buffer_size,
		{.TRANSFER_SRC},
		{.HOST_VISIBLE, .HOST_COHERENT},
		&staging_buffer,
		&staging_buffer_memory,
	)
	if result {
		log.error("Faild to create staging buffer")
		return true
	}
	data: rawptr
	vk.MapMemory(device, staging_buffer_memory, 0, buffer_size, {}, &data)
	mem.copy(data, &Input_Vertice_Indices[0], int(buffer_size))
	vk.UnmapMemory(device, staging_buffer_memory)

	result = create_buffer(
		ctx,
		buffer_size,
		{.INDEX_BUFFER, .TRANSFER_DST},
		{.DEVICE_LOCAL},
		&index_buffer,
		&index_buffer_memory,
	)
	if result {
		log.error("Faild to create index buffer")
		return true
	}

	copy_buffer(ctx, staging_buffer, index_buffer, buffer_size)

	vk.DestroyBuffer(device, staging_buffer, nil)
	vk.FreeMemory(device, staging_buffer_memory, nil)


	log.info("Success create index buffer")
	return false

}

find_memory_type :: proc(
	using ctx: ^VkContext,
	type_filter: u32,
	properties: vk.MemoryPropertyFlags,
) -> Maybe(u32) {
	mem_properties: vk.PhysicalDeviceMemoryProperties
	vk.GetPhysicalDeviceMemoryProperties(physical_device, &mem_properties)
	for i in 0 ..< mem_properties.memoryTypeCount {
		if (type_filter & (1 << i) == (1 << i)) &&
		   (mem_properties.memoryTypes[i].propertyFlags & properties == properties) {
			return i
		}
	}
	return nil
}

SwapChainSupportDetails :: struct {
	capailites:    vk.SurfaceCapabilitiesKHR,
	formats:       [dynamic]vk.SurfaceFormatKHR,
	present_modes: [dynamic]vk.PresentModeKHR,
}

is_complete :: proc(using indices: QueueFamilyIndices) -> bool {
	return graphics_family != nil && present_fanmily != nil
}

clean_up_swap_chain :: proc(using ctx: ^VkContext) {
	for i in swap_chain_frame_buffers {
		vk.DestroyFramebuffer(device, i, nil)
	}
	for img in swap_chain_image_view {
		vk.DestroyImageView(device, img, nil)
	}

	vk.DestroySwapchainKHR(device, ctx.swap_chain, nil)
}

recreate_swap_chain :: proc(using ctx: ^VkContext, window: glfw.WindowHandle) -> IsError {
	width, height := glfw.GetFramebufferSize(window)
	for width == 0 || height == 0 {
		width, height = glfw.GetFramebufferSize(window)
		glfw.WaitEvents()
	}

	vk.DeviceWaitIdle(device)

	clean_up_swap_chain(ctx)
	temp_log := context.logger
	success := false
	context.logger = log.nil_logger()
	defer {
		context.logger = temp_log
		if success {
			log.info("recreate swap chain success")
		}
	}

	if create_swap_chain(window, ctx) {
		return true
	}
	if create_image_views(ctx) {
		return true
	}
	if create_frame_buffers(ctx) {
		return true
	}
	success = true
	return false
}

draw_frame :: proc(using ctx: ^VkContext, window: glfw.WindowHandle) -> IsError {
	vk.WaitForFences(device, 1, &in_flight_fences[current_frame], true, max(u64))

	image_index: u32
	result := vk.AcquireNextImageKHR(
		device,
		swap_chain,
		max(u64),
		image_available_sems[current_frame],
		0,
		&image_index,
	)
	if result == .ERROR_OUT_OF_DATE_KHR {
		if recreate_swap_chain(ctx, window) {
			log.error("Failed to recreate swap chain")
			return true
		}
	} else if result != .SUCCESS && result != .SUBOPTIMAL_KHR {
		log.error("Failed to acquire swap chain image")
		return true
	}

	vk.ResetFences(device, 1, &in_flight_fences[current_frame])
	vk.ResetCommandBuffer(command_buffers[current_frame], {})

	record_command_buffer(ctx, command_buffers[current_frame], image_index)
	wait_sems: []vk.Semaphore = {image_available_sems[current_frame]}
	signal_sems: []vk.Semaphore = {render_finish_sems[current_frame]}
	wait_stage: []vk.PipelineStageFlags = {{.COLOR_ATTACHMENT_OUTPUT}}
	submit_info: vk.SubmitInfo = {
		sType                = .SUBMIT_INFO,
		waitSemaphoreCount   = 1,
		pWaitSemaphores      = &wait_sems[0],
		pWaitDstStageMask    = &wait_stage[0],
		commandBufferCount   = 1,
		pCommandBuffers      = &command_buffers[current_frame],
		signalSemaphoreCount = 1,
		pSignalSemaphores    = &signal_sems[0],
	}

	if vk.QueueSubmit(graphic_queue, 1, &submit_info, in_flight_fences[current_frame]) !=
	   .SUCCESS {
		log.error("Fail to submit draw command buffer")
		return true
	}
	swap_chains: []vk.SwapchainKHR = {swap_chain}

	present_info: vk.PresentInfoKHR = {
		sType              = .PRESENT_INFO_KHR,
		waitSemaphoreCount = 1,
		pWaitSemaphores    = &signal_sems[0],
		swapchainCount     = 1,
		pSwapchains        = &swap_chains[0],
		pImageIndices      = &image_index,
		pResults           = nil,
	}
	result = vk.QueuePresentKHR(present_queue, &present_info)
	if result == .ERROR_OUT_OF_DATE_KHR || result == .SUBOPTIMAL_KHR || frame_buffer_resized {
		frame_buffer_resized = false
		if recreate_swap_chain(ctx, window) {
			log.error("Failed to recreate swap chain")
			return true
		}
	} else if result != .SUCCESS {
		log.error("Failed to present swap chain image!")
		return true
	}
	current_frame = (current_frame + 1) % MAX_FRAME_IN_FLIGHT

	return false
}

create_sync_objects :: proc(using ctx: ^VkContext) -> IsError {
	resize(&image_available_sems, MAX_FRAME_IN_FLIGHT)
	resize(&render_finish_sems, MAX_FRAME_IN_FLIGHT)
	resize(&in_flight_fences, MAX_FRAME_IN_FLIGHT)
	sem_create_info: vk.SemaphoreCreateInfo = {
		sType = .SEMAPHORE_CREATE_INFO,
	}
	fence_info: vk.FenceCreateInfo = {
		sType = .FENCE_CREATE_INFO,
		flags = {.SIGNALED},
	}
	for i in 0 ..< MAX_FRAME_IN_FLIGHT {
		if vk.CreateSemaphore(device, &sem_create_info, nil, &image_available_sems[i]) !=
			   .SUCCESS ||
		   vk.CreateSemaphore(device, &sem_create_info, nil, &render_finish_sems[i]) != .SUCCESS ||
		   vk.CreateFence(device, &fence_info, nil, &in_flight_fences[i]) != .SUCCESS {
			return true
		}

	}

	log.info("Sync object create success")

	return false
}

record_command_buffer :: proc(
	using ctx: ^VkContext,
	target_buffer: vk.CommandBuffer,
	image_index: u32,
) -> IsError {
	begin_info: vk.CommandBufferBeginInfo = {
		sType            = .COMMAND_BUFFER_BEGIN_INFO,
		flags            = {.ONE_TIME_SUBMIT},
		pInheritanceInfo = nil,
	}
	if vk.BeginCommandBuffer(target_buffer, &begin_info) != .SUCCESS {
		log.error("Failed to begin command buffer")
		return true
	}
	clear_color: vk.ClearValue = {
		color = {float32 = {0.0, 0.0, 0.0, 1.0}},
	}
	render_pass_info: vk.RenderPassBeginInfo = {
		sType = .RENDER_PASS_BEGIN_INFO,
		renderPass = render_pass,
		framebuffer = swap_chain_frame_buffers[image_index],
		renderArea = {offset = {0, 0}, extent = swap_chain_extent},
		clearValueCount = 1,
		pClearValues = &clear_color,
	}
	vk.CmdBeginRenderPass(target_buffer, &render_pass_info, .INLINE)
	vk.CmdBindPipeline(target_buffer, .GRAPHICS, graphic_pipeline)

	view_port: vk.Viewport = {
		x        = 0.0,
		y        = 0.0,
		width    = (f32)(swap_chain_extent.width),
		height   = (f32)(swap_chain_extent.height),
		minDepth = 0.0,
		maxDepth = 1.0,
	}
	scissor: vk.Rect2D = {
		offset = {0, 0},
		extent = swap_chain_extent,
	}
	vertex_buffers: []vk.Buffer = {vertex_buffer}
	offsets: []vk.DeviceSize = {0}

	vk.CmdBindVertexBuffers(target_buffer, 0, 1, &vertex_buffers[0], &offsets[0])
	vk.CmdBindIndexBuffer(target_buffer, index_buffer, 0, .UINT16)
	vk.CmdSetViewport(target_buffer, 0, 1, &view_port)
	vk.CmdSetScissor(target_buffer, 0, 1, &scissor)

	vk.CmdDrawIndexed(target_buffer, (u32)(len(Input_Vertice_Indices)), 1, 0, 0, 0)
	vk.CmdEndRenderPass(target_buffer)

	if vk.EndCommandBuffer(target_buffer) != .SUCCESS {
		log.error("Failed to end command buffer")
		return true
	}

	return false
}

create_command_buffer :: proc(using ctx: ^VkContext) -> IsError {
	resize(&command_buffers, MAX_FRAME_IN_FLIGHT)
	alloc_info: vk.CommandBufferAllocateInfo = {
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool        = command_pool,
		level              = .PRIMARY,
		commandBufferCount = (u32)(len(command_buffers)),
	}
	if vk.AllocateCommandBuffers(device, &alloc_info, &ctx.command_buffers[0]) != .SUCCESS {
		log.error("Failed to create command buffer")
		return true
	}
	log.info("Command buffer create success")
	return false
}

create_command_pool :: proc(using ctx: ^VkContext) -> IsError {
	queue_family_indice := find_queue_families(surface, physical_device)
	assert(queue_family_indice.graphics_family != nil)
	assert(queue_family_indice.present_fanmily != nil)
	pool_info: vk.CommandPoolCreateInfo = {
		sType            = .COMMAND_POOL_CREATE_INFO,
		flags            = {.RESET_COMMAND_BUFFER},
		queueFamilyIndex = queue_family_indice.graphics_family.(u32),
	}
	if vk.CreateCommandPool(device, &pool_info, nil, &command_pool) != .SUCCESS {
		return true
	}
	log.info("Create command pool success")

	return false
}

create_frame_buffers :: proc(using ctx: ^VkContext) -> IsError {
	resize(&swap_chain_frame_buffers, len(swap_chain_image_view))

	for v, i in swap_chain_image_view {
		attachment: []vk.ImageView = {v}
		frame_buffer_info: vk.FramebufferCreateInfo = {
			sType           = .FRAMEBUFFER_CREATE_INFO,
			renderPass      = render_pass,
			attachmentCount = 1,
			pAttachments    = raw_data(attachment),
			width           = swap_chain_extent.width,
			height          = swap_chain_extent.height,
			layers          = 1,
		}
		if vk.CreateFramebuffer(device, &frame_buffer_info, nil, &swap_chain_frame_buffers[i]) !=
		   .SUCCESS {
			log.errorf("Failed to create %v frame buffer", i)
			return true
		}
	}
	log.info("Create frame buffer success")

	return false
}

create_graphic_pipeline :: proc(using ctx: ^VkContext) -> IsError {
	vert_shader_code, vert_err := os.read_entire_file_or_err(VERT_SHADER_PATH)
	defer delete(vert_shader_code)
	if vert_err != nil {
		log.errorf("Failed to Load file: %s\n", vert_err)
		return true
	}
	frag_shader_code, frag_err := os.read_entire_file_or_err(FRAGMENT_SHADER_PATH)
	defer delete(frag_shader_code)
	if frag_err != nil {
		log.errorf("Failed to Load file: %s\n", frag_err)
		return true
	}
	vert_shader_module, vm_err := create_shader_module(device, vert_shader_code[:])
	if vm_err {
		log.errorf("Failed to Create vert shader module")
		return true
	}
	defer vk.DestroyShaderModule(device, vert_shader_module, nil)
	frag_shader_module, fm_err := create_shader_module(device, frag_shader_code[:])
	if fm_err {
		log.errorf("Failed to Create frag shader module")
		return true
	}
	defer vk.DestroyShaderModule(device, frag_shader_module, nil)

	vert_shader_stage_info: vk.PipelineShaderStageCreateInfo = {
		sType               = .PIPELINE_SHADER_STAGE_CREATE_INFO,
		stage               = {.VERTEX},
		module              = vert_shader_module,
		pName               = "main",
		pSpecializationInfo = nil,
	}

	frag_shader_stage_info: vk.PipelineShaderStageCreateInfo = {
		sType               = .PIPELINE_SHADER_STAGE_CREATE_INFO,
		stage               = {.FRAGMENT},
		module              = frag_shader_module,
		pName               = "main",
		pSpecializationInfo = nil,
	}

	shader_stages: []vk.PipelineShaderStageCreateInfo = {
		vert_shader_stage_info,
		frag_shader_stage_info,
	}
	dynamic_states: []vk.DynamicState = {.VIEWPORT, .SCISSOR}
	dynamic_state: vk.PipelineDynamicStateCreateInfo = {
		sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
		dynamicStateCount = u32(len(dynamic_states)),
		pDynamicStates    = raw_data(dynamic_states),
	}

	binding_description := get_binding_description()
	attribute_description := get_attribute_description()

	vertex_input_info: vk.PipelineVertexInputStateCreateInfo = {
		sType                           = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
		vertexBindingDescriptionCount   = 1,
		pVertexBindingDescriptions      = &binding_description,
		vertexAttributeDescriptionCount = (u32)(len(attribute_description)),
		pVertexAttributeDescriptions    = &attribute_description[0],
	}

	input_assembly: vk.PipelineInputAssemblyStateCreateInfo = {
		sType                  = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		topology               = .TRIANGLE_LIST,
		primitiveRestartEnable = false,
	}

	viewport: vk.Viewport = {
		x        = 0.0,
		y        = 0.0,
		width    = (f32)(swap_chain_extent.width),
		height   = (f32)(swap_chain_extent.height),
		minDepth = 0.0,
		maxDepth = 1.0,
	}
	scissor: vk.Rect2D = {
		offset = {0, 0},
		extent = swap_chain_extent,
	}
	viewport_create_ingo: vk.PipelineViewportStateCreateInfo = {
		sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
		viewportCount = 1,
		pViewports    = &viewport,
		scissorCount  = 1,
		pScissors     = &scissor,
	}

	rasterizer: vk.PipelineRasterizationStateCreateInfo = {
		sType                   = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		depthClampEnable        = false,
		rasterizerDiscardEnable = false,
		polygonMode             = .FILL,
		lineWidth               = 1.0,
		cullMode                = {.BACK},
		frontFace               = .CLOCKWISE,
		depthBiasEnable         = false,
		depthBiasConstantFactor = 0.0,
		depthBiasSlopeFactor    = 0.0,
		depthBiasClamp          = 0.0,
	}

	multisampling: vk.PipelineMultisampleStateCreateInfo = {
		sType                 = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		sampleShadingEnable   = false,
		rasterizationSamples  = {._1},
		minSampleShading      = 1.0,
		pSampleMask           = nil,
		alphaToCoverageEnable = false,
		alphaToOneEnable      = false,
	}

	color_blend_attachment: vk.PipelineColorBlendAttachmentState = {
		colorWriteMask      = {.R, .G, .B, .A},
		blendEnable         = true,
		srcColorBlendFactor = .SRC_ALPHA,
		dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA,
		colorBlendOp        = .ADD,
		srcAlphaBlendFactor = .ONE,
		dstAlphaBlendFactor = .ZERO,
		alphaBlendOp        = .ADD,
	}

	color_blending: vk.PipelineColorBlendStateCreateInfo = {
		sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		logicOpEnable   = false,
		logicOp         = .COPY,
		attachmentCount = 1,
		pAttachments    = &color_blend_attachment,
		blendConstants  = {0, 0, 0, 0},
	}
	pipeline_layout_info: vk.PipelineLayoutCreateInfo = {
		sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
		setLayoutCount         = 0,
		pSetLayouts            = nil,
		pushConstantRangeCount = 0,
		pPushConstantRanges    = nil,
	}

	if vk.CreatePipelineLayout(device, &pipeline_layout_info, nil, &pipeline_layout) != .SUCCESS {
		log.error("Fail to create pipeline layout")
		return true
	}

	pipeline_info: vk.GraphicsPipelineCreateInfo = {
		sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
		stageCount          = 2,
		pStages             = raw_data(shader_stages),
		pVertexInputState   = &vertex_input_info,
		pInputAssemblyState = &input_assembly,
		pViewportState      = &viewport_create_ingo,
		pRasterizationState = &rasterizer,
		pMultisampleState   = &multisampling,
		pDepthStencilState  = nil,
		pColorBlendState    = &color_blending,
		pDynamicState       = &dynamic_state,
		layout              = pipeline_layout,
		renderPass          = render_pass,
		subpass             = 0,
		basePipelineHandle  = 0,
		basePipelineIndex   = -1,
	}

	if vk.CreateGraphicsPipelines(device, 0, 1, &pipeline_info, nil, &graphic_pipeline) !=
	   .SUCCESS {
		log.error("Fail to create graphic pipeline")
		return true
	}

	log.info("Graphic pipeline create success")

	return false
}

create_render_pass :: proc(using ctx: ^VkContext) -> IsError {
	color_attachment: vk.AttachmentDescription = {
		format         = swap_chain_image_format,
		samples        = {._1},
		loadOp         = .CLEAR,
		storeOp        = .STORE,
		stencilLoadOp  = .DONT_CARE,
		stencilStoreOp = .DONT_CARE,
		initialLayout  = .UNDEFINED,
		finalLayout    = .PRESENT_SRC_KHR,
	}
	color_attachment_ref: vk.AttachmentReference = {
		attachment = 0,
		layout     = .COLOR_ATTACHMENT_OPTIMAL,
	}
	dependency: vk.SubpassDependency = {
		srcSubpass    = vk.SUBPASS_EXTERNAL,
		dstSubpass    = 0,
		srcStageMask  = {.COLOR_ATTACHMENT_OUTPUT},
		srcAccessMask = {},
		dstStageMask  = {.COLOR_ATTACHMENT_OUTPUT},
		dstAccessMask = {.COLOR_ATTACHMENT_WRITE},
	}
	subpass: vk.SubpassDescription = {
		pipelineBindPoint    = .GRAPHICS,
		colorAttachmentCount = 1,
		pColorAttachments    = &color_attachment_ref,
	}

	render_pass_info: vk.RenderPassCreateInfo = {
		sType           = .RENDER_PASS_CREATE_INFO,
		attachmentCount = 1,
		pAttachments    = &color_attachment,
		subpassCount    = 1,
		pSubpasses      = &subpass,
		dependencyCount = 1,
		pDependencies   = &dependency,
	}

	if vk.CreateRenderPass(device, &render_pass_info, nil, &render_pass) != .SUCCESS {
		log.error("Failed to create render pass")
		return true
	}
	log.info("Render pass create success")

	return false
}

create_shader_module :: proc(device: vk.Device, code: []byte) -> (vk.ShaderModule, IsError) {
	create_info: vk.ShaderModuleCreateInfo = {
		sType    = .SHADER_MODULE_CREATE_INFO,
		codeSize = len(code),
		pCode    = (^u32)(&code[0]),
	}
	shader_module: vk.ShaderModule
	if vk.CreateShaderModule(device, &create_info, nil, &shader_module) != .SUCCESS {
		return shader_module, true
	}
	return shader_module, false
}

qurey_swap_chain_support :: proc(
	surface: vk.SurfaceKHR,
	device: vk.PhysicalDevice,
) -> SwapChainSupportDetails {
	using details: SwapChainSupportDetails
	vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(device, surface, &capailites)
	format_count: u32
	vk.GetPhysicalDeviceSurfaceFormatsKHR(device, surface, &format_count, nil)
	if format_count != 0 {
		resize(&formats, format_count)
		vk.GetPhysicalDeviceSurfaceFormatsKHR(device, surface, &format_count, raw_data(formats))
	}
	present_modes_count: u32
	vk.GetPhysicalDeviceSurfacePresentModesKHR(device, surface, &present_modes_count, nil)
	if present_modes_count != 0 {
		resize(&present_modes, present_modes_count)
		vk.GetPhysicalDeviceSurfacePresentModesKHR(
			device,
			surface,
			&present_modes_count,
			raw_data(present_modes),
		)
	}


	return details
}

swap_chain_support_detail_cleanup :: proc(details: SwapChainSupportDetails) {
	delete(details.present_modes)
	delete(details.formats)
}

choose_swap_surface_format :: proc(availables: []vk.SurfaceFormatKHR) -> vk.SurfaceFormatKHR {
	for i in availables {
		if i.format == vk.Format.B8G8R8A8_SRGB && i.colorSpace == vk.ColorSpaceKHR.SRGB_NONLINEAR {
			return i
		}
	}
	return availables[0]
}

choose_swap_present_mode :: proc(availables: []vk.PresentModeKHR) -> vk.PresentModeKHR {
	for i in availables {
		if i == vk.PresentModeKHR.MAILBOX {
			return i
		}
	}
	return vk.PresentModeKHR.FIFO
}

choose_swap_extent :: proc(
	window: glfw.WindowHandle,
	using capailites: vk.SurfaceCapabilitiesKHR,
) -> vk.Extent2D {
	if capailites.currentExtent.width != max(u32) {
		return currentExtent
	}
	width, height: i32 = glfw.GetFramebufferSize(window)
	actual_extent: vk.Extent2D = {(u32)(width), (u32)(height)}

	actual_extent.width = clamp(actual_extent.width, minImageExtent.width, maxImageExtent.width)
	actual_extent.height = clamp(
		actual_extent.height,
		minImageExtent.height,
		maxImageExtent.height,
	)
	return actual_extent
}
create_swap_chain :: proc(window: glfw.WindowHandle, ctx: ^VkContext) -> IsError {
	swap_chain_support := qurey_swap_chain_support(ctx.surface, ctx.physical_device)
	defer swap_chain_support_detail_cleanup(swap_chain_support)

	surface_format := choose_swap_surface_format(swap_chain_support.formats[:])
	present_mode := choose_swap_present_mode(swap_chain_support.present_modes[:])
	extent := choose_swap_extent(window, swap_chain_support.capailites)
	image_count := swap_chain_support.capailites.minImageCount + 1
	if swap_chain_support.capailites.maxImageCount > 0 &&
	   image_count > swap_chain_support.capailites.maxImageCount {
		image_count = swap_chain_support.capailites.maxImageCount
	}
	create_info: vk.SwapchainCreateInfoKHR = {
		sType                 = vk.StructureType.SWAPCHAIN_CREATE_INFO_KHR,
		surface               = ctx.surface,
		minImageCount         = image_count,
		imageFormat           = surface_format.format,
		imageColorSpace       = surface_format.colorSpace,
		imageExtent           = extent,
		imageArrayLayers      = 1,
		imageUsage            = {.COLOR_ATTACHMENT},
		imageSharingMode      = vk.SharingMode.EXCLUSIVE,
		queueFamilyIndexCount = 0,
		pQueueFamilyIndices   = nil,
		preTransform          = swap_chain_support.capailites.currentTransform,
		compositeAlpha        = {.OPAQUE},
		presentMode           = present_mode,
		clipped               = true,
		oldSwapchain          = 0,
	}
	indices := find_queue_families(ctx.surface, ctx.physical_device)
	queue_family_indices: []u32 = {indices.present_fanmily.(u32), indices.graphics_family.(u32)}
	if indices.graphics_family.(u32) != indices.present_fanmily.(u32) {
		create_info.imageSharingMode = vk.SharingMode.CONCURRENT
		create_info.queueFamilyIndexCount = u32(len(queue_family_indices))
		create_info.pQueueFamilyIndices = raw_data(queue_family_indices)
	}
	if vk.CreateSwapchainKHR(ctx.device, &create_info, nil, &ctx.swap_chain) != .SUCCESS {
		return true
	}

	vk.GetSwapchainImagesKHR(ctx.device, ctx.swap_chain, &image_count, nil)
	resize(&ctx.swap_chain_image, image_count)
	vk.GetSwapchainImagesKHR(
		ctx.device,
		ctx.swap_chain,
		&image_count,
		raw_data(ctx.swap_chain_image),
	)
	ctx.swap_chain_extent = extent
	ctx.swap_chain_image_format = surface_format.format

	log.info("Vk swapchain create success")

	return false
}

check_extension_support :: proc() {
	extension_count: u32
	vk.EnumerateInstanceExtensionProperties(nil, &extension_count, nil)
	extension := make([dynamic]vk.ExtensionProperties, extension_count, context.temp_allocator)
	defer delete(extension) // dynamic arrays remember their allocator
	vk.EnumerateInstanceExtensionProperties(nil, &extension_count, raw_data(extension))

	log.info("Available extensions: ")
	for &i in extension {
		fmt.printfln("\t- %s", i.extensionName)

	}
}
create_image_views :: proc(using ctx: ^VkContext) -> IsError {
	resize(&swap_chain_image_view, len(swap_chain_image))

	for v, i in swap_chain_image {
		create_info: vk.ImageViewCreateInfo = {
			sType = .IMAGE_VIEW_CREATE_INFO,
			image = v,
			viewType = .D2,
			format = swap_chain_image_format,
			components = {r = .IDENTITY, g = .IDENTITY, b = .IDENTITY, a = .IDENTITY},
			subresourceRange = {
				aspectMask = {.COLOR},
				baseMipLevel = 0,
				levelCount = 1,
				baseArrayLayer = 0,
				layerCount = 1,
			},
		}
		if vk.CreateImageView(device, &create_info, nil, &swap_chain_image_view[i]) != .SUCCESS {
			return true
		}
	}
	log.info("Image view create success")
	return false
}

is_device_suitable :: proc(surface: vk.SurfaceKHR, device: vk.PhysicalDevice) -> bool {
	indices := find_queue_families(surface, device)
	extensions_support := check_device_extension_support(device)
	swap_chain_adeuate := false
	if extensions_support {
		support := qurey_swap_chain_support(surface, device)
		defer swap_chain_support_detail_cleanup(support)
		swap_chain_adeuate = (len(support.formats) != 0) && (len(support.present_modes) != 0)
	}

	return is_complete(indices) && extensions_support && swap_chain_adeuate
}

check_device_extension_support :: proc(device: vk.PhysicalDevice) -> bool {
	extension_count: u32
	vk.EnumerateDeviceExtensionProperties(device, nil, &extension_count, nil)
	availables := make([dynamic]vk.ExtensionProperties, extension_count, context.temp_allocator)
	defer delete(availables)
	vk.EnumerateDeviceExtensionProperties(device, nil, &extension_count, raw_data(availables))
	require_extensions := make(map[cstring]bool, len(Device_Extensions))
	defer delete(require_extensions)
	for i in Device_Extensions {
		require_extensions[i] = true
	}
	for &i in availables {
		name := cstring(&i.extensionName[0])
		if name in require_extensions {
			delete_key(&require_extensions, name)
		}
	}


	return len(require_extensions) == 0
}

find_queue_families :: proc(
	surface: vk.SurfaceKHR,
	device: vk.PhysicalDevice,
) -> QueueFamilyIndices {
	indices: QueueFamilyIndices
	queue_family_count: u32 = 0
	vk.GetPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, nil)
	queue_families := make(
		[dynamic]vk.QueueFamilyProperties,
		queue_family_count,
		context.temp_allocator,
	)
	defer delete(queue_families)
	vk.GetPhysicalDeviceQueueFamilyProperties(
		device,
		&queue_family_count,
		raw_data(queue_families),
	)
	for v, i in queue_families {

		present_support: b32 = false
		if (v.queueFlags & {.GRAPHICS}) != nil {
			indices.graphics_family = (u32)(i)
		}
		vk.GetPhysicalDeviceSurfaceSupportKHR(device, (u32)(i), surface, &present_support)
		if present_support {
			indices.present_fanmily = (u32)(i)
		}
		if is_complete(indices) {
			break
		}
	}

	return indices
}

create_surface :: proc(ctx: ^VkContext, window: glfw.WindowHandle) -> IsError {
	if glfw.CreateWindowSurface(ctx.instance, window, nil, &ctx.surface) != .SUCCESS {
		return true
	}

	log.info("Windows surface create success")
	return false
}

pick_physical_device :: proc(ctx: ^VkContext) -> IsError {
	device_count: u32 = 0
	vk.EnumeratePhysicalDevices(ctx.instance, &device_count, nil)
	if (device_count == 0) {
		log.error("Failed to find devices with Vulkan support!")
		return true
	}
	devices := make([dynamic]vk.PhysicalDevice, device_count, context.temp_allocator)
	defer delete(devices)
	vk.EnumeratePhysicalDevices(ctx.instance, &device_count, raw_data(devices))
	for i in devices {
		if is_device_suitable(ctx.surface, i) {
			ctx.physical_device = i
			log.info("Pick physical device success")
			return false
		}
	}


	log.error("Failed to find a suitable device")
	return true
}

create_logical_device :: proc(ctx: ^VkContext) -> IsError {
	indices := find_queue_families(ctx.surface, ctx.physical_device)
	assert(indices.graphics_family != nil)
	assert(indices.present_fanmily != nil)
	uni_queue_families := make(map[u32]bool, context.temp_allocator)
	defer delete(uni_queue_families)
	uni_queue_families[indices.present_fanmily.(u32)] = true
	uni_queue_families[indices.graphics_family.(u32)] = true
	q_create_infos := make(
		[dynamic]vk.DeviceQueueCreateInfo,
		len(uni_queue_families),
		context.temp_allocator,
	)
	defer delete(q_create_infos)

	queue_priority: f32 = 1.0
	for i in uni_queue_families {
		queue_create_info: vk.DeviceQueueCreateInfo = {
			sType            = vk.StructureType.DEVICE_QUEUE_CREATE_INFO,
			queueFamilyIndex = i,
			//INFO: In this state must be true, because physical_device state will handle this
			queueCount       = 1,
			pQueuePriorities = &queue_priority,
		}
		q_create_infos[i] = queue_create_info

	}
	features: vk.PhysicalDeviceFeatures
	device_create_info: vk.DeviceCreateInfo = {
		sType                   = vk.StructureType.DEVICE_CREATE_INFO,
		pQueueCreateInfos       = raw_data(q_create_infos),
		queueCreateInfoCount    = (u32)(len(q_create_infos)),
		pEnabledFeatures        = &features,
		enabledExtensionCount   = (u32)(len(Device_Extensions)),
		ppEnabledExtensionNames = raw_data(Device_Extensions),
		enabledLayerCount       = 0,
	}
	when ODIN_DEBUG {
		device_create_info.enabledLayerCount = u32(len(Debug_Validaion_Layers))
		device_create_info.ppEnabledLayerNames = raw_data(Debug_Validaion_Layers)
	}

	if vk.CreateDevice(ctx.physical_device, &device_create_info, nil, &ctx.device) != .SUCCESS {
		return true
	}

	vk.GetDeviceQueue(ctx.device, indices.graphics_family.(u32), 0, &ctx.graphic_queue)
	vk.GetDeviceQueue(ctx.device, indices.present_fanmily.(u32), 0, &ctx.present_queue)
	log.info("Logical device create success")


	return false
}

init_window :: proc(using ctx: ^VkContext) -> (glfw.WindowHandle, IsError) {
	if glfw.Init() != glfw.TRUE {
		log.error("Failed to initialize GLFW")
		return nil, false
	}
	glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
	glfw.WindowHint(glfw.RESIZABLE, glfw.TRUE)
	window := glfw.CreateWindow(WIDTH, HIGHT, "Vulkan", nil, nil)
	if window == nil {
		log.error("Failed to create GLFW window")
		return nil, false
	}
	glfw.SetWindowUserPointer(window, ctx)
	glfw.SetFramebufferSizeCallback(window, frame_buffer_resize_callback)
	return window, true
}

frame_buffer_resize_callback :: proc "cdecl" (window: glfw.WindowHandle, width, hight: i32) {
	instance := (^VkContext)(glfw.GetWindowUserPointer(window))
	instance.frame_buffer_resized = true
}

create_instance :: proc(ctx: ^VkContext) -> IsError {
	appInfo: vk.ApplicationInfo = {
		sType              = vk.StructureType.APPLICATION_INFO,
		pApplicationName   = "Hello Triangle",
		applicationVersion = vk.MAKE_VERSION(1, 0, 0),
		pEngineName        = "No Engine",
		engineVersion      = vk.MAKE_VERSION(1, 0, 0),
		apiVersion         = vk.API_VERSION_1_0,
	}
	glfwExtensions := get_required_extensions()
	defer delete(glfwExtensions)

	createInfo: vk.InstanceCreateInfo = {
		sType                   = vk.StructureType.INSTANCE_CREATE_INFO,
		pApplicationInfo        = &appInfo,
		enabledExtensionCount   = (u32)(len(glfwExtensions)),
		ppEnabledExtensionNames = raw_data(glfwExtensions),
		enabledLayerCount       = 0,
		pNext                   = nil,
		flags                   = {},
	}

	when ODIN_OS == .Darwin {
		createInfo.flags = {.ENUMERATE_PORTABILITY_KHR}
	}

	when ODIN_DEBUG {
		if !check_validation_layer_support() {
			log.error("Validation layers requested, but not available!")
			return true
		}
		createInfo.enabledLayerCount = (u32)(len(Debug_Validaion_Layers))
		createInfo.ppEnabledLayerNames = raw_data(Debug_Validaion_Layers)
		info: vk.DebugUtilsMessengerCreateInfoEXT
		populate_debug_messenger_create_info(&info)
		createInfo.pNext = &info
	}

	if (vk.CreateInstance(&createInfo, nil, &ctx.instance) != vk.Result.SUCCESS) {
		return true
	}
	log.info("Create Vk Instance success")
	return false
}

get_required_extensions :: proc() -> [dynamic]cstring {
	glfw_extensions := [dynamic]cstring{}
	extensions := glfw.GetRequiredInstanceExtensions()
	append(&glfw_extensions, ..extensions)
    append(&glfw_extensions, vk.KHR_GET_PHYSICAL_DEVICE_PROPERTIES_2_EXTENSION_NAME)
	when ODIN_OS == .Darwin {
		append(&glfw_extensions, vk.KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME)
	}

	when ODIN_DEBUG {
		append(&glfw_extensions, vk.EXT_DEBUG_UTILS_EXTENSION_NAME)
	}

	return glfw_extensions
}

clean_up :: proc(ctx: ^VkContext, window: glfw.WindowHandle) {
	defer delete(ctx.swap_chain_frame_buffers)
	defer delete(ctx.swap_chain_image_view)
	defer delete(ctx.swap_chain_image)
	defer delete(ctx.image_available_sems)
	defer delete(ctx.render_finish_sems)
	defer delete(ctx.in_flight_fences)
	defer delete(ctx.command_buffers)

	clean_up_swap_chain(ctx)
	vk.DestroyBuffer(ctx.device, ctx.index_buffer, nil)
	vk.FreeMemory(ctx.device, ctx.index_buffer_memory, nil)
	vk.DestroyBuffer(ctx.device, ctx.vertex_buffer, nil)
	vk.FreeMemory(ctx.device, ctx.vertex_buffer_memory, nil)
	vk.DestroyPipeline(ctx.device, ctx.graphic_pipeline, nil)
	vk.DestroyPipelineLayout(ctx.device, ctx.pipeline_layout, nil)
	vk.DestroyRenderPass(ctx.device, ctx.render_pass, nil)

	for i in 0 ..< MAX_FRAME_IN_FLIGHT {
		vk.DestroyFence(ctx.device, ctx.in_flight_fences[i], nil)
		vk.DestroySemaphore(ctx.device, ctx.render_finish_sems[i], nil)
		vk.DestroySemaphore(ctx.device, ctx.image_available_sems[i], nil)
	}

	vk.DestroyCommandPool(ctx.device, ctx.command_pool, nil)
	vk.DestroyDevice(ctx.device, nil)
	when ODIN_DEBUG {
		vk.DestroyDebugUtilsMessengerEXT(ctx.instance, ctx.debug_messenger, nil)
	}
	vk.DestroySurfaceKHR(ctx.instance, ctx.surface, nil)
	vk.DestroyInstance(ctx.instance, nil)
	glfw.DestroyWindow(window)
	glfw.Terminate()
}


main :: proc() {
	when ODIN_DEBUG {
		debug_logger = log.create_console_logger(
			opt = {.Level, .Terminal_Color, .Short_File_Path, .Procedure, .Line},
		)
		context.logger = debug_logger
		defer log.destroy_console_logger(context.logger)

		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		context.allocator = mem.tracking_allocator(&track)
		defer mem.tracking_allocator_destroy(&track)

		defer {
			for _, leak in track.allocation_map {
				fmt.printf("%v leaked %v bytes\n", leak.location, leak.size)
			}
			for bad_free in track.bad_free_array {
				fmt.printf(
					"%v allocation %p was freed badly\n",
					bad_free.location,
					bad_free.memory,
				)
			}
		}
	} else {
		logger: log.Logger
		logger = log.create_console_logger(log.Level.Warning, opt = {.Level, .Terminal_Color})
		context.logger = logger
		defer log.destroy_console_logger(context.logger)
	}

	ctx: VkContext
	window: glfw.WindowHandle = init_window(&ctx) or_else panic("Can't init window")

	// odin default use dynamic link to vulkan,
	// and it will not auto get the function ptr(official Vulkan SDK will auto load most of it in somehow).
	vk.load_proc_addresses_global(rawptr(glfw.GetInstanceProcAddress))
	assert(vk.CreateInstance != nil, "Vulkan function pointers not loaded")
	check_extension_support()


	if create_instance(&ctx) {
		panic("Faild to create Vulkan Instance")
	}
	vk.load_proc_addresses_instance(ctx.instance)

	when ODIN_DEBUG {
		if setup_debug_messenger(&ctx) {
			log.error("Failed to create Debug Messenger.")
		}

	}
	if create_surface(&ctx, window) {
		panic("Failed to create surface")
	}
	if pick_physical_device(&ctx) {
		panic("Failed to pick device")
	}
	if create_logical_device(&ctx) {
		panic("Failed to logical device")
	}

	if create_swap_chain(window, &ctx) {
		panic("Failed to create swap chain")
	}

	if create_image_views(&ctx) {
		panic("Failed to create image view")
	}

	if create_render_pass(&ctx) {
		panic("Failed to create render pass")
	}

	if create_graphic_pipeline(&ctx) {
		panic("Failed to create graphic pipeline")
	}

	if create_frame_buffers(&ctx) {
		panic("Failed to create frame buffer")
	}

	if create_command_pool(&ctx) {
		panic("Failed to create command pool")
	}

	if create_vertex_buffer(&ctx) {
		panic("Failed to create vertex buffer ")
	}
	if create_index_buffer(&ctx) {
		panic("Failed to create index buffer ")
	}

	if create_command_buffer(&ctx) {
		panic("Failed to create command buffer")
	}

	if create_sync_objects(&ctx) {
		panic("Failed to cteate sync objects")
	}

	defer clean_up(&ctx, window)

	for !glfw.WindowShouldClose(window) {
		glfw.PollEvents()
		if draw_frame(&ctx, window) {
			panic("Failed to draw frame")
		}
	}
	vk.DeviceWaitIdle(ctx.device)
}

