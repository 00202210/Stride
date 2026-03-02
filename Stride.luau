--!strict
--!native
--!optimize 2

local Stride = {}

local buffer_create = buffer.create
local buffer_copy = buffer.copy
local buffer_len = buffer.len
local buffer_readu8 = buffer.readu8
local buffer_readi8 = buffer.readi8
local buffer_readu16 = buffer.readu16
local buffer_readi16 = buffer.readi16
local buffer_readu32 = buffer.readu32
local buffer_readi32 = buffer.readi32
local buffer_readf32 = buffer.readf32
local buffer_readf64 = buffer.readf64
local buffer_readstring = buffer.readstring
local buffer_writeu8 = buffer.writeu8
local buffer_writei8 = buffer.writei8
local buffer_writeu16 = buffer.writeu16
local buffer_writei16 = buffer.writei16
local buffer_writeu32 = buffer.writeu32
local buffer_writei32 = buffer.writei32
local buffer_writef32 = buffer.writef32
local buffer_writef64 = buffer.writef64
local buffer_writestring = buffer.writestring

local table_freeze = table.freeze
local table_sort = table.sort

local K_BOOL = 1
local K_U8 = 2
local K_I8 = 3
local K_U16 = 4
local K_I16 = 5
local K_U32 = 6
local K_I32 = 7
local K_F32 = 8
local K_F64 = 9
local K_STRING8 = 10
local K_STRING16 = 11
local K_STRING32 = 12

local SIZE_VARIABLE = -1
local BIG_BUFFER_SIZE = 1_000_000
local SCRATCH = buffer_create(BIG_BUFFER_SIZE)

export type SerializeType = {
	Name: string,
	Kind: number,
	Size: number,
}

type Field = {
	Name: string,
	Kind: number,
	Size: number,
	Offset: number,
}
type OrderedField = {
	Name: string,
	Type: SerializeType,
}

type Push = (data: {[string]: any}, target: buffer, offset: number) -> number
type Deserialize = (source: buffer, offset: number) -> ({[string]: any}, number)
type DeserializeInto = (target: {[string]: any}, source: buffer, offset: number) -> number

export type Schema = {
	Fields: {Field},
	Count: number,
	Size: number,
	IsFixed: boolean,
	ByName: {[string]: Field},
	Push: Push,
	Deserialize: Deserialize,
	DeserializeInto: DeserializeInto,
}

export type F32PairKernel = {
	Stride: number,
	Destination: number,
	Source: number,
	Update: (_buffer: buffer, count: number, passes: number?) -> (),
	SumDestination: (_buffer: buffer, count: number, passes: number?) -> number,
}

local function makeType(name: string, kind: number, size: number): SerializeType
	return table_freeze({
		Name = name,
		Kind = kind,
		Size = size,
	}) :: SerializeType
end

Stride.Boolean = makeType("Boolean", K_BOOL, 1)
Stride.Uint8 = makeType("Uint8", K_U8, 1)
Stride.Int8 = makeType("Int8", K_I8, 1)
Stride.Uint16 = makeType("Uint16", K_U16, 2)
Stride.Int16 = makeType("Int16", K_I16, 2)
Stride.Uint32 = makeType("Uint32", K_U32, 4)
Stride.Int32 = makeType("Int32", K_I32, 4)
Stride.Float32 = makeType("Float32", K_F32, 4)
Stride.Float64 = makeType("Float64", K_F64, 8)
Stride.String8 = makeType("String8", K_STRING8, SIZE_VARIABLE)
Stride.String16 = makeType("String16", K_STRING16, SIZE_VARIABLE)
Stride.String32 = makeType("String32", K_STRING32, SIZE_VARIABLE)

local function writeOne(kind: number, _buffer: buffer, offset: number, value: any): number
	if kind == K_BOOL then
		buffer_writeu8(_buffer, offset, value and 1 or 0)
		return offset + 1
	elseif kind == K_U8 then
		buffer_writeu8(_buffer, offset, value)
		return offset + 1
	elseif kind == K_I8 then
		buffer_writei8(_buffer, offset, value)
		return offset + 1
	elseif kind == K_U16 then
		buffer_writeu16(_buffer, offset, value)
		return offset + 2
	elseif kind == K_I16 then
		buffer_writei16(_buffer, offset, value)
		return offset + 2
	elseif kind == K_U32 then
		buffer_writeu32(_buffer, offset, value)
		return offset + 4
	elseif kind == K_I32 then
		buffer_writei32(_buffer, offset, value)
		return offset + 4
	elseif kind == K_F32 then
		buffer_writef32(_buffer, offset, value)
		return offset + 4
	elseif kind == K_F64 then
		buffer_writef64(_buffer, offset, value)
		return offset + 8
	elseif kind == K_STRING8 then
		local _string = value :: string
		local length = #_string
		buffer_writeu8(_buffer, offset, length)
		buffer_writestring(_buffer, offset + 1, _string)
		return offset + 1 + length
	elseif kind == K_STRING16 then
		local _string = value :: string
		local length = #_string
		buffer_writeu16(_buffer, offset, length)
		buffer_writestring(_buffer, offset + 2, _string)
		return offset + 2 + length
	else
		local _string = value :: string
		local length = #_string
		buffer_writeu32(_buffer, offset, length)
		buffer_writestring(_buffer, offset + 4, _string)
		return offset + 4 + length
	end
end

local function readOne(kind: number, _buffer: buffer, offset: number): (any, number)
	if kind == K_BOOL then
		return buffer_readu8(_buffer, offset) == 1, offset + 1
	elseif kind == K_U8 then
		return buffer_readu8(_buffer, offset), offset + 1
	elseif kind == K_I8 then
		return buffer_readi8(_buffer, offset), offset + 1
	elseif kind == K_U16 then
		return buffer_readu16(_buffer, offset), offset + 2
	elseif kind == K_I16 then
		return buffer_readi16(_buffer, offset), offset + 2
	elseif kind == K_U32 then
		return buffer_readu32(_buffer, offset), offset + 4
	elseif kind == K_I32 then
		return buffer_readi32(_buffer, offset), offset + 4
	elseif kind == K_F32 then
		return buffer_readf32(_buffer, offset), offset + 4
	elseif kind == K_F64 then
		return buffer_readf64(_buffer, offset), offset + 8
	elseif kind == K_STRING8 then
		local length = buffer_readu8(_buffer, offset)
		return buffer_readstring(_buffer, offset + 1, length), offset + 1 + length
	elseif kind == K_STRING16 then
		local length = buffer_readu16(_buffer, offset)
		return buffer_readstring(_buffer, offset + 2, length), offset + 2 + length
	else
		local length = buffer_readu32(_buffer, offset)
		return buffer_readstring(_buffer, offset + 4, length), offset + 4 + length
	end
end

local function compileFixedPush(fields: {Field}, size: number): Push
	local count = #fields

	if count == 2 and fields[1].Kind == K_F32 and fields[2].Kind == K_F32 then
		local key1 = fields[1].Name
		local key2 = fields[2].Name
		local offset1 = fields[1].Offset
		local offset2 = fields[2].Offset
		return function(data: {[string]: any}, _buffer: buffer, offset: number): number
			local base = offset
			buffer_writef32(_buffer, base + offset1, data[key1])
			buffer_writef32(_buffer, base + offset2, data[key2])
			return base + size
		end
	end

	return function(data: {[string]: any}, _buffer: buffer, offset: number): number
		local base = offset
		for index = 1, count do
			local field = fields[index]
			local kind = field.Kind
			local value = data[field.Name]
			local at = base + field.Offset

			if kind == K_BOOL then
				buffer_writeu8(_buffer, at, value and 1 or 0)
			elseif kind == K_U8 then
				buffer_writeu8(_buffer, at, value)
			elseif kind == K_I8 then
				buffer_writei8(_buffer, at, value)
			elseif kind == K_U16 then
				buffer_writeu16(_buffer, at, value)
			elseif kind == K_I16 then
				buffer_writei16(_buffer, at, value)
			elseif kind == K_U32 then
				buffer_writeu32(_buffer, at, value)
			elseif kind == K_I32 then
				buffer_writei32(_buffer, at, value)
			elseif kind == K_F32 then
				buffer_writef32(_buffer, at, value)
			else
				buffer_writef64(_buffer, at, value)
			end
		end

		return base + size
	end
end

local function compileFixedDeserialize(fields: {Field}, size: number): Deserialize
	local count = #fields

	if count == 2 and fields[1].Kind == K_F32 and fields[2].Kind == K_F32 then
		local key1 = fields[1].Name
		local key2 = fields[2].Name
		local offset1 = fields[1].Offset
		local offset2 = fields[2].Offset
		return function(_buffer: buffer, offset: number): ({[string]: any}, number)
			local out = {}
			local base = offset
			out[key1] = buffer_readf32(_buffer, base + offset1)
			out[key2] = buffer_readf32(_buffer, base + offset2)
			return out, base + size
		end
	end

	return function(_buffer: buffer, offset: number): ({[string]: any}, number)
		local out = {} :: {[string]: any}
		local base = offset

		for index = 1, count do
			local field = fields[index]
			local kind = field.Kind
			local at = base + field.Offset

			if kind == K_BOOL then
				out[field.Name] = buffer_readu8(_buffer, at) == 1
			elseif kind == K_U8 then
				out[field.Name] = buffer_readu8(_buffer, at)
			elseif kind == K_I8 then
				out[field.Name] = buffer_readi8(_buffer, at)
			elseif kind == K_U16 then
				out[field.Name] = buffer_readu16(_buffer, at)
			elseif kind == K_I16 then
				out[field.Name] = buffer_readi16(_buffer, at)
			elseif kind == K_U32 then
				out[field.Name] = buffer_readu32(_buffer, at)
			elseif kind == K_I32 then
				out[field.Name] = buffer_readi32(_buffer, at)
			elseif kind == K_F32 then
				out[field.Name] = buffer_readf32(_buffer, at)
			else
				out[field.Name] = buffer_readf64(_buffer, at)
			end
		end

		return out, base + size
	end
end

local function compileFixedDeserializeInto(fields: {Field}, size: number): DeserializeInto
	local count = #fields

	if count == 2 and fields[1].Kind == K_F32 and fields[2].Kind == K_F32 then
		local key1 = fields[1].Name
		local key2 = fields[2].Name
		local offset1 = fields[1].Offset
		local offset2 = fields[2].Offset
		return function(target: {[string]: any}, _buffer: buffer, offset: number): number
			local base = offset
			target[key1] = buffer_readf32(_buffer, base + offset1)
			target[key2] = buffer_readf32(_buffer, base + offset2)
			return base + size
		end
	end

	return function(target: {[string]: any}, _buffer: buffer, offset: number): number
		local base = offset
		for index = 1, count do
			local field = fields[index]
			local kind = field.Kind
			local at = base + field.Offset

			if kind == K_BOOL then
				target[field.Name] = buffer_readu8(_buffer, at) == 1
			elseif kind == K_U8 then
				target[field.Name] = buffer_readu8(_buffer, at)
			elseif kind == K_I8 then
				target[field.Name] = buffer_readi8(_buffer, at)
			elseif kind == K_U16 then
				target[field.Name] = buffer_readu16(_buffer, at)
			elseif kind == K_I16 then
				target[field.Name] = buffer_readi16(_buffer, at)
			elseif kind == K_U32 then
				target[field.Name] = buffer_readu32(_buffer, at)
			elseif kind == K_I32 then
				target[field.Name] = buffer_readi32(_buffer, at)
			elseif kind == K_F32 then
				target[field.Name] = buffer_readf32(_buffer, at)
			else
				target[field.Name] = buffer_readf64(_buffer, at)
			end
		end
		return base + size
	end
end

local function compileDynamicPush(fields: {Field}): Push
	local count = #fields
	return function(data: {[string]: any}, _buffer: buffer, offset: number): number
		local at = offset
		for index = 1, count do
			local field = fields[index]
			at = writeOne(field.Kind, _buffer, at, data[field.Name])
		end
		return at
	end
end

local function compileDynamicDeserialize(fields: {Field}): Deserialize
	local count = #fields
	return function(_buffer: buffer, offset: number): ({[string]: any}, number)
		local out = {}
		local at = offset
		for index = 1, count do
			local field = fields[index]
			local value
			value, at = readOne(field.Kind, _buffer, at)
			out[field.Name] = value
		end
		return out, at
	end
end

local function compileDynamicDeserializeInto(fields: {Field}): DeserializeInto
	local count = #fields
	return function(target: {[string]: any}, _buffer: buffer, offset: number): number
		local at = offset
		for index = 1, count do
			local field = fields[index]
			local value
			value, at = readOne(field.Kind, _buffer, at)
			target[field.Name] = value
		end
		return at
	end
end

local function buildSchema(fields: {Field}, count: number, isFixed: boolean, size: number, byName: {[string]: Field}): Schema
	local push: Push
	local deserialize: Deserialize
	local deserializeInto: DeserializeInto

	if isFixed then
		push = compileFixedPush(fields, size)
		deserialize = compileFixedDeserialize(fields, size)
		deserializeInto = compileFixedDeserializeInto(fields, size)
	else
		size = 0
		push = compileDynamicPush(fields)
		deserialize = compileDynamicDeserialize(fields)
		deserializeInto = compileDynamicDeserializeInto(fields)
	end

	return table_freeze({
		Fields = fields,
		Count = count,
		Size = size,
		IsFixed = isFixed,
		ByName = byName,
		Push = push,
		Deserialize = deserialize,
		DeserializeInto = deserializeInto,
	}) :: Schema
end

function Stride.Schema(params: {[string]: SerializeType}): Schema
	local names = {}
	local count = 0
	for name in params do
		count += 1
		names[count] = name
	end

	assert(count ~= 0, "Schema must have at least one field")

	table_sort(names)

	local fields = table.create(count) :: {Field}
	local byName = {} :: {[string]: Field}
	local isFixed = true
	local fixedSize = 0

	for index = 1, count do
		local name = names[index]
		local field = params[name]

		assert(field ~= nil, `Missing type for field {name}`)

		local kind = field.Kind
		local size = field.Size
		local offset = fixedSize

		if size == SIZE_VARIABLE then
			isFixed = false
			offset = 0
		else
			fixedSize += size
		end

		field = {
			Name = name,
			Kind = kind,
			Size = size,
			Offset = offset,
		}

		fields[index] = field
		byName[name] = field
	end

	return buildSchema(fields, count, isFixed, fixedSize, byName)
end

function Stride.SchemaOrdered(fieldsOrdered: {OrderedField}): Schema
	local count = #fieldsOrdered

	assert(count ~= 0, "SchemaOrdered must have at least one field")

	local fields = table.create(count) :: {Field}
	local byName = {} :: {[string]: Field}
	local isFixed = true
	local size = 0

	for index = 1, count do
		local entry = fieldsOrdered[index]
		local name = entry.Name
		local field = entry.Type

		assert(byName[name] == nil, `Duplicate field name: {name}`)

		local kind = field.Kind
		local fieldSize = field.Size
		local offset = size
		if fieldSize == SIZE_VARIABLE then
			isFixed = false
			offset = 0
		else
			size += fieldSize
		end

		field = {
			Name = name,
			Kind = kind,
			Size = fieldSize,
			Offset = offset,
		}

		fields[index] = field
		byName[name] = field
	end

	return buildSchema(fields, count, isFixed, size, byName)
end

function Stride.RecordSize(schema: Schema): number
	return schema.Size
end

function Stride.NewBuffer(schema: Schema, capacity: number): buffer
	assert(schema.Size ~= 0, "NewBuffer requires a fixed-size schema")

	return buffer_create(schema.Size * capacity)
end

function Stride.Push(schema: Schema, data: {[string]: any}, target: buffer, offset: number?): number
	return schema.Push(data, target, offset or 0)
end

function Stride.Deserialize(schema: Schema, source: buffer, offset: number?): ({[string]: any}, number)
	return schema.Deserialize(source, offset or 0)
end

function Stride.DeserializeInto(schema: Schema, target: {[string]: any}, source: buffer, offset: number?): number
	return schema.DeserializeInto(target, source, offset or 0)
end

function Stride.Serialize(schema: Schema, data: {[string]: any}): buffer
	if schema.IsFixed then
		local size = schema.Size
		local out = buffer_create(size)
		schema.Push(data, out, 0)
		return out
	end

	local offset = schema.Push(data, SCRATCH, 0)
	local out = buffer_create(offset)
	buffer_copy(out, 0, SCRATCH, 0, offset)
	return out
end

function Stride.SerializeMany(schema: Schema, rows: {{[string]: any}}): buffer
	if schema.IsFixed then
		local size = schema.Size
		local rowCount = #rows
		local out = buffer_create(size * rowCount)
		local offset = 0
		for index = 1, rowCount do
			offset = schema.Push(rows[index], out, offset)
		end
		return out
	end

	local offset = 0
	for index = 1, #rows do
		offset = schema.Push(rows[index], SCRATCH, offset)
	end

	local out = buffer_create(offset)
	buffer_copy(out, 0, SCRATCH, 0, offset)
	return out
end

function Stride.ByteLength(_buffer: buffer): number
	return buffer_len(_buffer)
end

function Stride.UpdateAddF32RawUnsafe(
	_buffer: buffer,
	count: number,
	stride: number,
	destination: number,
	source: number,
	passes: number
)
	for _ = 1, passes do
		local destinationOffset = destination
		local sourceOffset = source

		for _ = 1, count do
			buffer_writef32(_buffer, destinationOffset, buffer_readf32(_buffer, destinationOffset) + buffer_readf32(_buffer, sourceOffset))
			destinationOffset += stride
			sourceOffset += stride
		end
	end
end

function Stride.UpdateAddF32Raw(
	_buffer: buffer,
	count: number,
	stride: number,
	destination: number,
	source: number,
	passes: number?
)
	if count <= 0 then
		return
	end

	passes = passes or 1
	if passes <= 0 then
		return
	end

	Stride.UpdateAddF32RawUnsafe(_buffer, count, stride, destination, source, passes)
end

function Stride.SumF32RawUnsafe(
	_buffer: buffer,
	count: number,
	stride: number,
	offset: number,
	passes: number
): number
	local total = 0.0
	for _ = 1, passes do
		local at = offset
		for _ = 1, count do
			total += buffer_readf32(_buffer, at)
			at += stride
		end
	end

	return total
end

function Stride.SumF32Raw(
	_buffer: buffer,
	count: number,
	stride: number,
	offset: number,
	passes: number?
): number
	if count <= 0 then
		return 0
	end

	passes = passes or 1
	if passes <= 0 then
		return 0
	end

	return Stride.SumF32RawUnsafe(_buffer, count, stride, offset, passes)
end

function Stride.UpdateAddF32(
	schema: Schema,
	_buffer: buffer,
	count: number,
	destination: string,
	source: string,
	passes: number?
)
	if count <= 0 then
		return
	end

	local destination = schema.ByName[destination]
	assert(destination ~= nil, `Unknown destination field: {destination}`)

	local source = schema.ByName[source]
	assert(source ~= nil, `Unknown source field: {source}`)

	assert(destination.Kind == K_F32 or destination.Kind == K_F64, `UpdateAddF32 requires Float32 or Float64 destination field, got {destination.Kind}`)

	local stride = schema.Size
	assert(stride > 0, "UpdateAddF32 requires fixed-size schema")

	passes = passes or 1
	if passes <= 0 then
		return
	end

	Stride.UpdateAddF32RawUnsafe(_buffer, count, stride, destination.Offset, source.Offset, passes)
end

function Stride.SumF32(schema: Schema, _buffer: buffer, count: number, field: string, passes: number?): number
	if count <= 0 then
		return 0
	end

	local fieldMeta = schema.ByName[field]
	assert(field ~= nil, `Unknown field: {field}`)
	assert(fieldMeta.Kind == K_F32, `SumF32 requires Float32 field, got {fieldMeta.Kind}`)

	local stride = schema.Size
	assert(stride > 0, "SumF32 requires fixed-size schema")

	passes = passes or 1
	if passes <= 0 then
		return 0
	end

	return Stride.SumF32RawUnsafe(_buffer, count, stride, fieldMeta.Offset, passes)
end

function Stride.CompileF32Pair(schema: Schema, destination: string, source: string): F32PairKernel
	local destination = schema.ByName[destination]
	assert(destination ~= nil, `Unknown destination field: {destination}`)

	local source = schema.ByName[source]
	assert(source ~= nil, `Unknown source field: {source}`)
	assert(destination.Kind == K_F32 or source.Kind == K_F32, `UpdateAddF32 requires Float32 destination field, got {destination.Kind}`)

	local stride = schema.Size
	assert(stride > 0, "CompileF32Pair requires fixed-size schema")

	local destinationOffset = destination.Offset
	local sourceOffset = source.Offset

	local function update(_buffer: buffer, count: number, passes: number?)
		if count <= 0 then
			return
		end

		passes = passes or 1
		if passes <= 0 then
			return
		end

		Stride.UpdateAddF32RawUnsafe(_buffer, count, stride, destinationOffset, sourceOffset, passes)
	end

	local function sumDestination(_buffer: buffer, count: number, passes: number?): number
		if count <= 0 then
			return 0
		end

		passes = passes or 1
		if passes <= 0 then
			return 0
		end

		return Stride.SumF32RawUnsafe(_buffer, count, stride, destinationOffset, passes)
	end

	return table_freeze({
		Stride = stride,
		DestinationOffset = destinationOffset,
		SourceOffset = sourceOffset,
		Update = update,
		SumDestination = sumDestination,
	}) :: F32PairKernel
end

return Stride
