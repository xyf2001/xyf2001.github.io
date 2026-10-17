class_name GPURender
extends RefCounted
## 输出纹理始终属于RenderingServer主RD，可由Texture2DRD直接共享给Canvas。
## 没有ImageTexture.update、texture_get_data或RGBA整图读回。
static func create_output(rd: RenderingDevice, size: int) -> RID:
	var format := RDTextureFormat.new()
	format.width = size
	format.height = size
	format.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	return rd.texture_create(format, RDTextureView.new())
