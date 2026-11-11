// Byte ranges allow one unusually large object to be drawn without reading its whole block.
export class NativeGeometryReader
{
    constructor (baseUrl)
    {
        this.baseUrl = baseUrl;
        this.headers = new Map ();
        this.readRequests = 0;
        this.readBytes = 0;
    }

    async Bytes (url, first, count, signal)
    {
        this.readRequests += 1;
        const response = await fetch (url, { signal, headers : { Range : 'bytes=' + first + '-' + (first + count - 1) } });
        if (response.status !== 206 || Number (response.headers.get ('Content-Length')) !== count) {
            response.body?.cancel ();
            throw new Error ('本地模型缓存不支持所需的分段读取。');
        }
        const data = await response.arrayBuffer ();
        this.readBytes += data.byteLength;
        if (data.byteLength !== count) {
            throw new Error ('模型分段数据不完整。');
        }
        return data;
    }

    ResourceKey (part)
    {
        const url = new URL (part.entry.data.url, this.baseUrl).href;
        return url + (part.header ? (part.line ? ':l:' : ':t:') + part.start + ':' + part.count : ':whole');
    }

    Data (part)
    {
        return part.header ? { ...part.entry.data, indexBase : part.line ? 0 : part.start, lineBase : part.line ? part.start : 0 } : part.entry.data;
    }

    async Parts (entry, budget, signal)
    {
        const cached = this.CachedParts (entry, budget);
        if (cached) {
            return cached;
        }
        const url = new URL (entry.data.url, this.baseUrl).href;
        const raw = await this.Bytes (url, 0, 32, signal);
        const values = new Uint32Array (raw);
        if (values[0] !== 0x3144334f || ![1, 2, 3].includes (values[1])) {
            throw new Error ('模型块格式不正确。');
        }
        const header = { version : values[1], vertices : values[2], indices : values[3], lines : values[4], colors : values[5] !== 0,
            colorComponents : values[1] >= 3 ? 4 : 3, uvs : values[1] >= 2 && (values[6] & 1) !== 0,
            uv1 : values[1] >= 3 && (values[6] & 2) !== 0, tangents : values[1] >= 3 && (values[7] & 1) !== 0 };
        header.positions = 32;
        header.normals = 32 + header.vertices * 12;
        header.faces = 32 + header.vertices * 24;
        header.linePositions = header.faces + header.indices * 4;
        header.colorPositions = header.linePositions + header.lines * 12;
        header.uvPositions = header.colorPositions + (header.colors ? header.vertices * header.colorComponents * 4 : 0);
        header.uv1Positions = header.uvPositions + (header.uvs ? header.vertices * 8 : 0);
        header.tangentPositions = header.uv1Positions + (header.uv1 ? header.vertices * 8 : 0);
        header.expected = header.tangentPositions + (header.tangents ? header.vertices * 16 : 0);
        this.headers.set (url, header);
        return this.CachedParts (entry, budget);
    }

    CachedParts (entry, budget)
    {
        if (entry.data.bytes <= budget / 2) {
            return [{ key : entry.data.id, entry, estimate : entry.data.bytes }];
        }
        const header = this.headers.get (new URL (entry.data.url, this.baseUrl).href);
        if (!header) {
            return null;
        }
        const width = entry.data.drawMode === 'points' ? 1 : entry.data.drawMode === 'lines' ? 2 : 3;
        if (header.expected !== entry.data.bytes || header.indices % width || header.lines % 2) {
            throw new Error ('模型块数据不完整。');
        }

        const parts = [];
        const indicesPerPart = Math.max (width, Math.min (24000, Math.floor (budget / 512 / width) * width));
        for (let start = 0; start < header.indices; start += indicesPerPart) {
            const count = Math.min (indicesPerPart, header.indices - start);
            parts.push ({ key : entry.data.id + ':t' + start + ':' + count, entry, header, start, count,
                estimate : 32 + count * (28 + (header.colors ? header.colorComponents * 4 : 0) + (header.uvs ? 8 : 0) + (header.uv1 ? 8 : 0) + (header.tangents ? 16 : 0)) });
        }
        const linesPerPart = Math.max (2, Math.min (24000, Math.floor (budget / 48 / 2) * 2));
        for (let start = 0; start < header.lines; start += linesPerPart) {
            const count = Math.min (linesPerPart, header.lines - start);
            parts.push ({ key : entry.data.id + ':l' + start + ':' + count, entry, header, start, count, line : true, estimate : 32 + count * 12 });
        }
        return parts;
    }

    async Read (part, signal)
    {
        const data = part.entry.data;
        const url = new URL (data.url, this.baseUrl).href;
        if (!part.header) {
            this.readRequests += 1;
            const response = await fetch (url, { signal });
            if (!response.ok || Number (response.headers.get ('Content-Length')) !== data.bytes) {
                response.body?.cancel ();
                throw new Error ('模型块长度不正确。');
            }
            const buffer = await response.arrayBuffer ();
            this.readBytes += buffer.byteLength;
            return { data, buffer };
        }
        const h = part.header;
        if (part.line) {
            const buffer = new ArrayBuffer (32 + part.count * 12);
            new Uint32Array (buffer, 0, 8).set ([0x3144334f, 2, 0, 0, part.count, 0, 0, 0]);
            new Uint8Array (buffer, 32).set (new Uint8Array (await this.Bytes (url, h.linePositions + part.start * 12, part.count * 12, signal)));
            return { data : { ...data, indexBase : 0, lineBase : part.start }, buffer };
        }
        const source = new Uint32Array (await this.Bytes (url, h.faces + part.start * 4, part.count * 4, signal));
        const unique = [...new Set (source)].sort ((a, b) => a - b);
        if (unique.length && unique[unique.length - 1] >= h.vertices) {
            throw new Error ('模型块顶点索引不正确。');
        }
        const remap = new Map (unique.map ((value, index) => [value, index]));
        const n = unique.length;
        const buffer = new ArrayBuffer (32 + n * (24 + (h.colors ? h.colorComponents * 4 : 0) + (h.uvs ? 8 : 0) + (h.uv1 ? 8 : 0) + (h.tangents ? 16 : 0)) + source.length * 4);
        new Uint32Array (buffer, 0, 8).set ([0x3144334f, h.version >= 3 ? 3 : 2, n, source.length, 0, Number (h.colors), Number (h.uvs) | (Number (h.uv1) << 1), Number (h.tangents)]);
        const faces = new Uint32Array (buffer, 32 + n * 24, source.length);
        source.forEach ((index, i) => { faces[i] = remap.get (index); });
        const readAttribute = async (offset, components, outputOffset) => {
            const output = new Float32Array (buffer, outputOffset, n * components);
            for (let begin = 0; begin < n;) {
                let end = begin + 1;
                while (end < n && unique[end] - unique[end - 1] <= 64 && unique[end] - unique[begin] < 16384) {
                    end += 1;
                }
                const values = new Float32Array (await this.Bytes (url, offset + unique[begin] * components * 4,
                    (unique[end - 1] - unique[begin] + 1) * components * 4, signal));
                for (let i = begin; i < end; i++) {
                    const at = (unique[i] - unique[begin]) * components;
                    output.set (values.subarray (at, at + components), i * components);
                }
                begin = end;
            }
        };
        await readAttribute (h.positions, 3, 32);
        await readAttribute (h.normals, 3, 32 + n * 12);
        let offset = 32 + n * 24 + source.length * 4;
        if (h.colors) {
            await readAttribute (h.colorPositions, h.colorComponents, offset);
            offset += n * h.colorComponents * 4;
        }
        if (h.uvs) {
            await readAttribute (h.uvPositions, 2, offset);
            offset += n * 8;
        }
        if (h.uv1) {
            await readAttribute (h.uv1Positions, 2, offset);
            offset += n * 8;
        }
        if (h.tangents) {
            await readAttribute (h.tangentPositions, 4, offset);
        }
        return { data : { ...data, indexBase : part.start, lineBase : 0 }, buffer };
    }
}
