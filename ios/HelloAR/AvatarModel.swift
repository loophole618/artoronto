// Reads a glTF character export: body-part meshes and rig joints.
import Foundation
import UIKit
import simd

struct AvatarModel {
    struct Part {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var indices: [UInt32] = []
        var texture: Int?
    }
    var parts: [String: Part] = [:]
    var joints: [String: SIMD3<Float>] = [:]
    var images: [Int: CGImage] = [:]

    enum LoadError: Error { case notGLTF }

    static func load(url: URL) throws -> AvatarModel {
        let data = try Data(contentsOf: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LoadError.notGLTF }
        let dir = url.deletingLastPathComponent()
        func list(_ key: String) -> [[String: Any]] { json[key] as? [[String: Any]] ?? [] }
        func num(_ v: Any?) -> Int? { (v as? NSNumber)?.intValue }
        func nums(_ v: Any?) -> [Float]? { (v as? [NSNumber])?.map { $0.floatValue } }

        func bytes(uri: String) -> Data? {
            if uri.hasPrefix("data:"), let comma = uri.firstIndex(of: ",") {
                return Data(base64Encoded: String(uri[uri.index(after: comma)...]))
            }
            return try? Data(contentsOf: dir.appendingPathComponent(uri.removingPercentEncoding ?? uri))
        }
        let buffers = list("buffers").map { bytes(uri: $0["uri"] as? String ?? "") ?? Data() }
        let views = list("bufferViews")
        let accessors = list("accessors")

        func viewBytes(_ i: Int) -> Data? {
            guard i < views.count, let b = num(views[i]["buffer"]), b < buffers.count else { return nil }
            let off = num(views[i]["byteOffset"]) ?? 0, len = num(views[i]["byteLength"]) ?? 0
            let buf = buffers[b]
            guard off + len <= buf.count else { return nil }
            return Data(buf[buf.startIndex + off ..< buf.startIndex + off + len])
        }

        func read(_ i: Int) -> (values: [Double], n: Int) {
            guard i < accessors.count else { return ([], 1) }
            let a = accessors[i]
            let count = num(a["count"]) ?? 0
            let n = ["SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16][a["type"] as? String ?? "SCALAR"] ?? 1
            let ct = num(a["componentType"]) ?? 5126
            let size = (ct == 5126 || ct == 5125) ? 4 : ((ct == 5123 || ct == 5122) ? 2 : 1)
            guard let vi = num(a["bufferView"]), let bytes = viewBytes(vi) else { return ([Double](repeating: 0, count: count * n), n) }
            let start = num(a["byteOffset"]) ?? 0
            let stride = num(views[vi]["byteStride"]) ?? (size * n)
            var out = [Double](); out.reserveCapacity(count * n)
            bytes.withUnsafeBytes { raw in
                for k in 0..<count {
                    for c in 0..<n {
                        let o = start + k * stride + c * size
                        guard o + size <= raw.count else { out.append(0); continue }
                        switch ct {
                        case 5126: out.append(Double(raw.loadUnaligned(fromByteOffset: o, as: Float.self)))
                        case 5125: out.append(Double(raw.loadUnaligned(fromByteOffset: o, as: UInt32.self)))
                        case 5123: out.append(Double(raw.loadUnaligned(fromByteOffset: o, as: UInt16.self)))
                        case 5122: out.append(Double(raw.loadUnaligned(fromByteOffset: o, as: Int16.self)))
                        case 5121: out.append(Double(raw.load(fromByteOffset: o, as: UInt8.self)))
                        default: out.append(Double(raw.load(fromByteOffset: o, as: Int8.self)))
                        }
                    }
                }
            }
            return (out, n)
        }

        var model = AvatarModel()
        for (i, im) in list("images").enumerated() {
            var d: Data?
            if let uri = im["uri"] as? String { d = bytes(uri: uri) }
            else if let bv = num(im["bufferView"]) { d = viewBytes(bv) }
            if let d, let cg = UIImage(data: d)?.cgImage { model.images[i] = cg }
        }
        let textures = list("textures"), materials = list("materials")
        func textureImage(material: Int?) -> Int? {
            guard let m = material, m < materials.count,
                  let pbr = materials[m]["pbrMetallicRoughness"] as? [String: Any],
                  let bct = pbr["baseColorTexture"] as? [String: Any],
                  let t = num(bct["index"]), t < textures.count else { return nil }
            return num(textures[t]["source"])
        }

        let nodes = list("nodes"), meshes = list("meshes")
        func localMatrix(_ n: [String: Any]) -> simd_float4x4 {
            if let m = nums(n["matrix"]), m.count == 16 {
                return simd_float4x4(SIMD4(m[0], m[1], m[2], m[3]), SIMD4(m[4], m[5], m[6], m[7]),
                                     SIMD4(m[8], m[9], m[10], m[11]), SIMD4(m[12], m[13], m[14], m[15]))
            }
            let t = nums(n["translation"]) ?? [0, 0, 0]
            let r = nums(n["rotation"]) ?? [0, 0, 0, 1]
            let s = nums(n["scale"]) ?? [1, 1, 1]
            var m = simd_float4x4(simd_quatf(ix: r[0], iy: r[1], iz: r[2], r: r[3]))
            m.columns.0 *= s[0]; m.columns.1 *= s[1]; m.columns.2 *= s[2]
            m.columns.3 = SIMD4(t[0], t[1], t[2], 1)
            return m
        }

        func addMesh(_ mi: Int, name: String, world w: simd_float4x4) {
            guard mi < meshes.count else { return }
            let rot = simd_float3x3(SIMD3(w.columns.0.x, w.columns.0.y, w.columns.0.z),
                                    SIMD3(w.columns.1.x, w.columns.1.y, w.columns.1.z),
                                    SIMD3(w.columns.2.x, w.columns.2.y, w.columns.2.z))
            var part = model.parts[name] ?? Part()
            for p in meshes[mi]["primitives"] as? [[String: Any]] ?? [] {
                guard let attrs = p["attributes"] as? [String: Any], let pa = num(attrs["POSITION"]) else { continue }
                let base = UInt32(part.positions.count)
                let pos = read(pa).values
                let count = pos.count / 3
                for k in 0..<count {
                    let v = w * SIMD4(Float(pos[3 * k]), Float(pos[3 * k + 1]), Float(pos[3 * k + 2]), 1)
                    part.positions.append(SIMD3(v.x, v.y, v.z))
                }
                if let na = num(attrs["NORMAL"]) {
                    let nv = read(na).values
                    for k in 0..<count {
                        let n = rot * SIMD3(Float(nv[3 * k]), Float(nv[3 * k + 1]), Float(nv[3 * k + 2]))
                        part.normals.append(simd_length(n) > 0 ? simd_normalize(n) : SIMD3(0, 1, 0))
                    }
                }
                if let ta = num(attrs["TEXCOORD_0"]) {
                    let tv = read(ta).values
                    for k in 0..<count { part.uvs.append(SIMD2(Float(tv[2 * k]), 1 - Float(tv[2 * k + 1]))) }
                }
                if let ia = num(p["indices"]) {
                    part.indices += read(ia).values.map { base + UInt32($0) }
                } else {
                    part.indices += (0..<UInt32(count)).map { base + $0 }
                }
                if part.texture == nil { part.texture = textureImage(material: num(p["material"])) }
            }
            if part.normals.count != part.positions.count { part.normals = [] }
            if part.uvs.count != part.positions.count { part.uvs = [] }
            model.parts[name] = part
        }

        func walk(_ i: Int, _ parent: simd_float4x4) {
            guard i < nodes.count else { return }
            let n = nodes[i]
            let w = parent * localMatrix(n)
            let name = n["name"] as? String ?? ""
            if name.hasSuffix("Rig_Att") {
                let joint = String(name.dropLast(4))
                if model.joints[joint] == nil { model.joints[joint] = SIMD3(w.columns.3.x, w.columns.3.y, w.columns.3.z) }
            }
            if name.hasSuffix("_Geo"), let mi = num(n["mesh"]) {
                addMesh(mi, name: String(name.dropLast(4)), world: w)
            }
            for c in n["children"] as? [NSNumber] ?? [] { walk(c.intValue, w) }
        }
        let scenes = list("scenes")
        let sceneIndex = num(json["scene"]) ?? 0
        let roots = sceneIndex < scenes.count ? (scenes[sceneIndex]["nodes"] as? [NSNumber] ?? []).map(\.intValue)
                                              : Array(nodes.indices)
        for r in roots { walk(r, matrix_identity_float4x4) }
        if model.parts.isEmpty { throw LoadError.notGLTF }
        return model
    }
}
