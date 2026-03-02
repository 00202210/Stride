--!strict
--!native
--!optimize 2
local Stride = {}

export type FieldType = "u8" | "i8" | "u16" | "i16" | "u32" | "i32" | "f32" | "f64"

type Read = (buffer: buffer, offset: number) -> number
type Write = (buffer: buffer, offset: number, value: number) -> ()
type Getter = (index: number) -> number
type Setter = (index: number, value: number) -> ()
type Adder = (index: number) -> ()
type Accumulator = () -> ()

type BufferReference = {value: buffer}
type PairAdderMap = {[string]: Adder}
type PairAccumulatorMap = {[string]: Accumulator}

type FieldMeta = {
	offset: number,
	_type: FieldType,
	_read: Read,
	_write: Write,
}

export type Layout = {
	stride: number,
	_fields: {[string]: FieldMeta},
	_order: {string},
}

export type Store = {
	Layout: Layout,
	Count: number,
	Capacity: number,
	_stride: number,
	_fields: {[string]: FieldMeta},
	_getters: {[string]: Getter},
	_setters: {[string]: Setter},
	_adders: {[string]: PairAdderMap},
	_accumulators: {[string]: PairAccumulatorMap},
	_lastAccumulatorDestination: string?,
	_lastAccumulatorSource: string?,
	_lastAccumulator: Accumulator?,
	_bufferReference: BufferReference,

	_buffer: buffer,

	Reserve: (self: Store, capacity: number) -> (),
	Create: (self: Store) -> number,
	CreateMany: (self: Store, amount: number) -> number,
	Destroy: (self: Store, index: number) -> (),

	Accessor: (self: Store, field: string) -> (Getter, Setter),
	PinnedAccessor: (self: Store, field: string) -> (Getter, Setter),
	AddAccessor: (self: Store, destination: string, source: string) -> Adder,
	PinnedAddAccessor: (self: Store, destination: string, source: string) -> Adder,
	Accumulator: (self: Store, destination: string, source: string) -> Accumulator,
	ForEachDense: (self: Store, fn: (index: number) -> ()) -> (),
	Accumulate: (self: Store, destination: string, source: string) -> (),
	AccumulateN: (self: Store, destination: string, source: string, passes: number) -> (),

	Get: (self: Store, index: number, field: string) -> number,
	Set: (self: Store, index: number, field: string, value: number) -> (),

	__index: Store,
}

local buffer_create = buffer.create
local buffer_copy = buffer.copy
local buffer_readu8 = buffer.readu8
local buffer_readi8 = buffer.readi8
local buffer_readu16 = buffer.readu16
local buffer_readi16 = buffer.readi16
local buffer_readu32 = buffer.readu32
local buffer_readi32 = buffer.readi32
local buffer_readf32 = buffer.readf32
local buffer_readf64 = buffer.readf64
local buffer_writeu8 = buffer.writeu8
local buffer_writei8 = buffer.writei8
local buffer_writeu16 = buffer.writeu16
local buffer_writei16 = buffer.writei16
local buffer_writeu32 = buffer.writeu32
local buffer_writei32 = buffer.writei32
local buffer_writef32 = buffer.writef32
local buffer_writef64 = buffer.writef64

local TYPE_INFO: {[FieldType]: {size: number, read: Read, write: Write}} = {
	u8 = {size = 1, read = buffer_readu8, write = buffer_writeu8},
	i8 = {size = 1, read = buffer_readi8, write = buffer_writei8},
	u16 = {size = 2, read = buffer_readu16, write = buffer_writeu16},
	i16 = {size = 2, read = buffer_readi16, write = buffer_writei16},
	u32 = {size = 4, read = buffer_readu32, write = buffer_writeu32},
	i32 = {size = 4, read = buffer_readi32, write = buffer_writei32},
	f32 = {size = 4, read = buffer_readf32, write = buffer_writef32},
	f64 = {size = 8, read = buffer_readf64, write = buffer_writef64},
}

function Stride.Layout(fieldsOrdered: {[number]: {name: string, _type: FieldType}}): Layout
	local fields: {[string]: FieldMeta} = {}
	local order = table.create(#fieldsOrdered) :: {string}
	local stride = 0

	for index = 1, #fieldsOrdered do
		local field = fieldsOrdered[index]
		local name, _type = field.name, field._type
		local info = TYPE_INFO[_type]

		assert(info ~= nil, `Unknown field type: {tostring(_type)}`)
		assert(fields[name] == nil, `Duplicate field name: {name}`)

		fields[name] = {
			offset = stride,
			_type = _type,
			_read = info.read,
			_write = info.write,
		}
		order[index] = name
		stride += info.size
	end

	return {
		stride = stride,
		_fields = fields,
		_order = order,
	}
end

local Store = {} :: Store
Store.__index = Store

local function NewBufferFor(stride: number, capacity: number): buffer
	return buffer_create(stride * capacity)
end

function Stride.new(layout: Layout, capacity: number?): Store
	local initialCapacity = capacity or 256
	if initialCapacity < 1 then
		initialCapacity = 1
	end

	local initialBuffer = NewBufferFor(layout.stride, initialCapacity)
	local self = setmetatable({}, Store) :: Store
	self.Layout = layout
	self._stride = layout.stride
	self._fields = layout._fields
	self._getters = {}
	self._setters = {}
	self._adders = {}
	self._accumulators = {}
	self._lastAccumulatorDestination = nil
	self._lastAccumulatorSource = nil
	self._lastAccumulator = nil
	self._bufferReference = {value = initialBuffer}
	self.Count = 0
	self.Capacity = initialCapacity
	self._buffer = initialBuffer
	return self
end

function Store.Reserve(self: Store, capacity: number)
	assert(capacity >= self.Count, "Reserve capacity must be >= Count")
	if capacity <= self.Capacity then
		return
	end

	local stride = self._stride
	local newBuffer = NewBufferFor(stride, capacity)
	local count = self.Count
	if count > 0 then
		buffer_copy(newBuffer, 0, self._buffer, 0, stride * count)
	end

	self._buffer = newBuffer
	self._bufferReference.value = newBuffer
	self.Capacity = capacity
end

function Store.Create(self: Store): number
	local nextIndex = self.Count + 1
	if nextIndex > self.Capacity then
		local newCapacity = self.Capacity * 2
		if newCapacity < nextIndex then
			newCapacity = nextIndex
		end
		Store.Reserve(self, newCapacity)
	end

	self.Count = nextIndex
	return nextIndex
end

function Store.CreateMany(self: Store, amount: number): number
	assert(amount >= 0, "CreateMany amount must be >= 0")
	if amount == 0 then
		return self.Count + 1
	end

	local firstIndex = self.Count + 1
	local newCount = self.Count + amount
	if newCount > self.Capacity then
		local newCapacity = self.Capacity
		while newCapacity < newCount do
			newCapacity *= 2
		end
		Store.Reserve(self, newCapacity)
	end

	self.Count = newCount
	return firstIndex
end

function Store.Destroy(self: Store, index: number)
	local count = self.Count
	assert(index >= 1 and index <= count, "Destroy index out of range")

	if index ~= count then
		local stride = self._stride
		local destination = (index - 1) * stride
		local source = (count - 1) * stride
		buffer_copy(self._buffer, destination, self._buffer, source, stride)
	end

	self.Count = count - 1
end

function Store.Accessor(self: Store, field: string)
	local cachedGet = self._getters[field]
	if cachedGet ~= nil then
		return cachedGet, self._setters[field] :: Setter
	end

	local meta = self._fields[field]
	assert(meta ~= nil, `Unknown field: {field}`)

	local stride = self._stride
	local offset = meta.offset - stride
	local _type = meta._type
	local bufferReference = self._bufferReference
	local get: Getter
	local set: Setter

	if _type == "u8" then
		get = function(index: number): number
			return buffer_readu8(bufferReference.value, index * stride + offset)
		end
		set = function(index: number, value: number)
			buffer_writeu8(bufferReference.value, index * stride + offset, value)
		end
	elseif _type == "i8" then
		get = function(index: number): number
			return buffer_readi8(bufferReference.value, index * stride + offset)
		end
		set = function(index: number, value: number)
			buffer_writei8(bufferReference.value, index * stride + offset, value)
		end
	elseif _type == "u16" then
		get = function(index: number): number
			return buffer_readu16(bufferReference.value, index * stride + offset)
		end
		set = function(index: number, value: number)
			buffer_writeu16(bufferReference.value, index * stride + offset, value)
		end
	elseif _type == "i16" then
		get = function(index: number): number
			return buffer_readi16(bufferReference.value, index * stride + offset)
		end
		set = function(index: number, value: number)
			buffer_writei16(bufferReference.value, index * stride + offset, value)
		end
	elseif _type == "u32" then
		get = function(index: number): number
			return buffer_readu32(bufferReference.value, index * stride + offset)
		end
		set = function(index: number, value: number)
			buffer_writeu32(bufferReference.value, index * stride + offset, value)
		end
	elseif _type == "i32" then
		get = function(index: number): number
			return buffer_readi32(bufferReference.value, index * stride + offset)
		end
		set = function(index: number, value: number)
			buffer_writei32(bufferReference.value, index * stride + offset, value)
		end
	elseif _type == "f32" then
		get = function(index: number): number
			return buffer_readf32(bufferReference.value, index * stride + offset)
		end
		set = function(index: number, value: number)
			buffer_writef32(bufferReference.value, index * stride + offset, value)
		end
	else -- f64
		get = function(index: number): number
			return buffer_readf64(bufferReference.value, index * stride + offset)
		end
		set = function(index: number, value: number)
			buffer_writef64(bufferReference.value, index * stride + offset, value)
		end
	end

	self._getters[field] = get
	self._setters[field] = set
	return get, set
end

function Store.PinnedAccessor(self: Store, field: string)
	local meta = self._fields[field]
	assert(meta ~= nil, `Unknown field: {field}`)

	local stride = self._stride
	local offset = meta.offset - stride
	local _buffer = self._buffer
	local _type = meta._type

	if _type == "u8" then
		return function(index: number): number
			return buffer_readu8(_buffer, index * stride + offset)
		end, function(index: number, value: number)
			buffer_writeu8(_buffer, index * stride + offset, value)
		end
	elseif _type == "i8" then
		return function(index: number): number
			return buffer_readi8(_buffer, index * stride + offset)
		end, function(index: number, value: number)
			buffer_writei8(_buffer, index * stride + offset, value)
		end
	elseif _type == "u16" then
		return function(index: number): number
			return buffer_readu16(_buffer, index * stride + offset)
		end, function(index: number, value: number)
			buffer_writeu16(_buffer, index * stride + offset, value)
		end
	elseif _type == "i16" then
		return function(index: number): number
			return buffer_readi16(_buffer, index * stride + offset)
		end, function(index: number, value: number)
			buffer_writei16(_buffer, index * stride + offset, value)
		end
	elseif _type == "u32" then
		return function(index: number): number
			return buffer_readu32(_buffer, index * stride + offset)
		end, function(index: number, value: number)
			buffer_writeu32(_buffer, index * stride + offset, value)
		end
	elseif _type == "i32" then
		return function(index: number): number
			return buffer_readi32(_buffer, index * stride + offset)
		end, function(index: number, value: number)
			buffer_writei32(_buffer, index * stride + offset, value)
		end
	elseif _type == "f32" then
		return function(index: number): number
			return buffer_readf32(_buffer, index * stride + offset)
		end, function(index: number, value: number)
			buffer_writef32(_buffer, index * stride + offset, value)
		end
	else -- f64
		return function(index: number): number
			return buffer_readf64(_buffer, index * stride + offset)
		end, function(index: number, value: number)
			buffer_writef64(_buffer, index * stride + offset, value)
		end
	end
end

function Store.AddAccessor(self: Store, destination: string, source: string): Adder
	local addersBySource = self._adders[destination]
	if addersBySource ~= nil then
		local cached = addersBySource[source]
		if cached ~= nil then
			return cached
		end
	else
		addersBySource = {}
		self._adders[destination] = addersBySource
	end

	local destinationMeta = self._fields[destination]
	assert(destinationMeta ~= nil, `Unknown destination field: {destination}`)

	local sourceMeta = self._fields[source]
	assert(sourceMeta ~= nil, `Unknown source field: {source}`)

	local stride = self._stride
	local destinationOffset = destinationMeta.offset - stride
	local sourceOffset = sourceMeta.offset - stride
	local bufferReference = self._bufferReference
	local add: Adder

	if destinationMeta._type == "f32" and sourceMeta._type == "f32" then
		add = function(index: number)
			local _buffer = bufferReference.value
			local base = index * stride
			local destinationByteOffset = base + destinationOffset
			buffer_writef32(
				_buffer,
				destinationByteOffset,
				buffer_readf32(_buffer, destinationByteOffset) + buffer_readf32(_buffer, base + sourceOffset)
			)
		end
	else
		local destinationRead = destinationMeta._read
		local destinationWrite = destinationMeta._write
		local sourceRead = sourceMeta._read
		add = function(index: number)
			local _buffer = bufferReference.value
			local base = index * stride
			local destinationByteOffset = base + destinationOffset
			destinationWrite(
				_buffer,
				destinationByteOffset,
				destinationRead(_buffer, destinationByteOffset) + sourceRead(_buffer, base + sourceOffset)
			)
		end
	end

	addersBySource[source] = add
	return add
end

function Store.PinnedAddAccessor(self: Store, destination: string, source: string): Adder
	local destinationMeta = self._fields[destination]
	assert(destinationMeta ~= nil, `Unknown destination field: {destination}`)

	local sourceMeta = self._fields[source]
	assert(sourceMeta ~= nil, `Unknown source field: {source}`)

	local stride = self._stride
	local destinationOffset = destinationMeta.offset - stride
	local sourceOffset = sourceMeta.offset - stride
	local _buffer = self._buffer

	if destinationMeta._type == "f32" and sourceMeta._type == "f32" then
		return function(index: number)
			local base = index * stride
			local destinationByteOffset = base + destinationOffset
			buffer_writef32(
				_buffer,
				destinationByteOffset,
				buffer_readf32(_buffer, destinationByteOffset) + buffer_readf32(_buffer, base + sourceOffset)
			)
		end
	end

	local destinationRead = destinationMeta._read
	local destinationWrite = destinationMeta._write
	local sourceRead = sourceMeta._read
	return function(index: number)
		local base = index * stride
		local destinationByteOffset = base + destinationOffset
		destinationWrite(
			_buffer,
			destinationByteOffset,
			destinationRead(_buffer, destinationByteOffset) + sourceRead(_buffer, base + sourceOffset)
		)
	end
end

function Store.Accumulator(self: Store, destination: string, source: string): Accumulator
	local accumulatorsBySource = self._accumulators[destination]
	if accumulatorsBySource ~= nil then
		local cached = accumulatorsBySource[source]
		if cached ~= nil then
			return cached
		end
	else
		accumulatorsBySource = {}
		self._accumulators[destination] = accumulatorsBySource
	end

	local destinationMeta = self._fields[destination]
	assert(destinationMeta ~= nil, `Unknown destination field: {destination}`)

	local sourceMeta = self._fields[source]
	assert(sourceMeta ~= nil, `Unknown source field: {source}`)

	local stride = self._stride
	local destinationOffset = destinationMeta.offset
	local sourceOffset = sourceMeta.offset
	local bufferReference = self._bufferReference
	local run: Accumulator

	if destinationMeta._type == "f32" and sourceMeta._type == "f32" then
		run = function()
			local count = self.Count
			if count == 0 then
				return
			end

			local _buffer = bufferReference.value
			local destinationByteOffset = destinationOffset
			local sourceByteOffset = sourceOffset
			local fastCount = count - (count % 4)

			for _ = 1, fastCount, 4 do
				buffer_writef32(_buffer, destinationByteOffset, buffer_readf32(_buffer, destinationByteOffset) + buffer_readf32(_buffer, sourceByteOffset))
				destinationByteOffset += stride
				sourceByteOffset += stride

				buffer_writef32(_buffer, destinationByteOffset, buffer_readf32(_buffer, destinationByteOffset) + buffer_readf32(_buffer, sourceByteOffset))
				destinationByteOffset += stride
				sourceByteOffset += stride

				buffer_writef32(_buffer, destinationByteOffset, buffer_readf32(_buffer, destinationByteOffset) + buffer_readf32(_buffer, sourceByteOffset))
				destinationByteOffset += stride
				sourceByteOffset += stride

				buffer_writef32(_buffer, destinationByteOffset, buffer_readf32(_buffer, destinationByteOffset) + buffer_readf32(_buffer, sourceByteOffset))
				destinationByteOffset += stride
				sourceByteOffset += stride
			end

			for _ = fastCount + 1, count do
				buffer_writef32(_buffer, destinationByteOffset, buffer_readf32(_buffer, destinationByteOffset) + buffer_readf32(_buffer, sourceByteOffset))
				destinationByteOffset += stride
				sourceByteOffset += stride
			end
		end
	else
		local destinationRead = destinationMeta._read
		local destinationWrite = destinationMeta._write
		local sourceRead = sourceMeta._read
		run = function()
			local count = self.Count
			if count == 0 then
				return
			end

			local _buffer = bufferReference.value
			local destinationByteOffset = destinationOffset
			local sourceByteOffset = sourceOffset
			local fastCount = count - (count % 4)

			for _ = 1, fastCount, 4 do
				destinationWrite(_buffer, destinationByteOffset, destinationRead(_buffer, destinationByteOffset) + sourceRead(_buffer, sourceByteOffset))
				destinationByteOffset += stride
				sourceByteOffset += stride

				destinationWrite(_buffer, destinationByteOffset, destinationRead(_buffer, destinationByteOffset) + sourceRead(_buffer, sourceByteOffset))
				destinationByteOffset += stride
				sourceByteOffset += stride

				destinationWrite(_buffer, destinationByteOffset, destinationRead(_buffer, destinationByteOffset) + sourceRead(_buffer, sourceByteOffset))
				destinationByteOffset += stride
				sourceByteOffset += stride

				destinationWrite(_buffer, destinationByteOffset, destinationRead(_buffer, destinationByteOffset) + sourceRead(_buffer, sourceByteOffset))
				destinationByteOffset += stride
				sourceByteOffset += stride
			end

			for _ = fastCount + 1, count do
				destinationWrite(_buffer, destinationByteOffset, destinationRead(_buffer, destinationByteOffset) + sourceRead(_buffer, sourceByteOffset))
				destinationByteOffset += stride
				sourceByteOffset += stride
			end
		end
	end

	accumulatorsBySource[source] = run
	return run
end

function Store.ForEachDense(self: Store, fn: (index: number) -> ())
	for index = 1, self.Count do
		fn(index)
	end
end

function Store.Accumulate(self: Store, destination: string, source: string)
	local run = self._lastAccumulator
	if run ~= nil and self._lastAccumulatorDestination == destination and self._lastAccumulatorSource == source then
		run()
		return
	end

	run = self:Accumulator(destination, source)
	self._lastAccumulatorDestination = destination
	self._lastAccumulatorSource = source
	self._lastAccumulator = run
	
	run()
end

function Store.AccumulateN(self: Store, destination: string, source: string, passes: number)
	assert(passes >= 0, "AccumulateN passes must be >= 0")
	if passes == 0 then
		return
	end

	local run = self._lastAccumulator
	if run == nil or self._lastAccumulatorDestination ~= destination or self._lastAccumulatorSource ~= source then
		run = self:Accumulator(destination, source)
		
		self._lastAccumulatorDestination = destination
		self._lastAccumulatorSource = source
		self._lastAccumulator = run
	end
	
	assert(run ~= nil, "No accumulator")

	local fastPasses = passes - (passes % 4)
	for _ = 1, fastPasses, 4 do
		run()
		run()
		run()
		run()
	end
	
	assert(run ~= nil, "No accumulator")
	
	for _ = fastPasses + 1, passes do
		run()
	end
end

function Store.Get(self: Store, index: number, field: string): number
	local meta = self._fields[field]
	
	assert(meta ~= nil, `Unknown field: {field}`)
	assert(index >= 1 and index <= self.Count, "Get index out of range")
	
	return meta._read(self._buffer, index * self._stride + (meta.offset - self._stride))
end

function Store.Set(self: Store, index: number, field: string, value: number)
	local meta = self._fields[field]
	
	assert(meta ~= nil, `Unknown field: {field}`)
	assert(index >= 1 and index <= self.Count, "Set index out of range")
	
	meta._write(self._buffer, index * self._stride + (meta.offset - self._stride), value)
end

return Stride
