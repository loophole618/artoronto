import RealityKit
import UIKit
import simd

// The spine's vertebrae: one glowing solid per chakra, root to crown.
// Shape = the chakra's element as its classical (Platonic) solid:
//   earth = cube, water = icosahedron, fire = tetrahedron (point down, like
//   Manipura's downward triangle), air = octahedron, ether = dodecahedron.
// Ajna = a bead of light; Sahasrara = a flat white disc (the full moon).
// Colour = the petal colours from art-studio's build_chakras.py (the texts,
// not the modern rainbow), so the walk-spine matches the chakra spheres.
enum Chakra {
    static func all() -> [(name: String, mesh: MeshResource, material: RealityKit.Material)] {
        let r: Float = 0.035   // circumradius, metres (solids ~7 cm across)
        return [
            ("Muladhara", MeshResource.generateBox(size: r * 1.15),        glow(1.00, 0.03, 0.14)),
            ("Svadhisthana", icosahedron(radius: r),                      glow(1.00, 0.30, 0.02)),
            ("Manipura", tetrahedronPointDown(radius: r * 1.15),          glow(0.08, 0.28, 1.00)),
            ("Anahata", octahedron(radius: r),                            glow(1.00, 0.10, 0.08)),
            ("Vishuddha", dodecahedron(radius: r),                        glow(0.58, 0.12, 1.00)),
            ("Ajna", MeshResource.generateSphere(radius: r * 0.6),        glow(0.90, 0.97, 1.00)),
            ("Sahasrara", MeshResource.generateCylinder(height: r * 0.18, radius: r), glow(1.00, 1.00, 1.00)),
        ]
    }

    static func glow(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> RealityKit.Material {
        let c = UIColor(red: r, green: g, blue: b, alpha: 1)
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: c)
        m.emissiveColor = .init(color: c)
        m.emissiveIntensity = 0.8
        m.roughness = .init(floatLiteral: 0.35)
        m.metallic = .init(floatLiteral: 0.0)
        m.faceCulling = .none
        return m
    }

    // MARK: solids

    static func octahedron(radius: Float) -> MeshResource {
        let v: [SIMD3<Float>] = [[1,0,0], [-1,0,0], [0,1,0], [0,-1,0], [0,0,1], [0,0,-1]]
        return flatMesh(v, equilateralTriangles(v), radius)
    }

    static func tetrahedronPointDown(radius: Float) -> MeshResource {
        let a = sqrtf(8.0 / 9.0), b = sqrtf(2.0 / 9.0), c = sqrtf(2.0 / 3.0)
        let v: [SIMD3<Float>] = [[0,-1,0], [a,1.0/3.0,0], [-b,1.0/3.0,c], [-b,1.0/3.0,-c]]
        return flatMesh(v, equilateralTriangles(v), radius)
    }

    static func icosahedronVertices() -> [SIMD3<Float>] {
        let p: Float = (1 + sqrtf(5)) / 2
        var v: [SIMD3<Float>] = []
        for a in [-1, 1] as [Float] {
            for b in [-1, 1] as [Float] {
                v.append([0, a, b * p]); v.append([a, b * p, 0]); v.append([a * p, 0, b])
            }
        }
        return v
    }

    static func icosahedron(radius: Float) -> MeshResource {
        let v = icosahedronVertices()
        return flatMesh(v, equilateralTriangles(v), radius)
    }

    /// The dual of the icosahedron: its 20 face centres are the dodecahedron's
    /// vertices; the 5 faces around each icosahedron vertex make one pentagon.
    static func dodecahedron(radius: Float) -> MeshResource {
        let iv = icosahedronVertices()
        let tris = equilateralTriangles(iv)
        let dv: [SIMD3<Float>] = tris.map { t in simd_normalize(iv[t[0]] + iv[t[1]] + iv[t[2]]) }
        var faces: [[Int]] = []
        for i in iv.indices {
            let around = tris.indices.filter { tris[$0].contains(i) }
            let n = simd_normalize(iv[i])
            let centre = around.reduce(SIMD3<Float>(repeating: 0)) { $0 + dv[$1] } / Float(around.count)
            let u = simd_normalize(dv[around[0]] - centre)
            let w = simd_cross(n, u)
            func angle(_ k: Int) -> Float {
                let d = dv[k] - centre
                return atan2f(simd_dot(d, w), simd_dot(d, u))
            }
            faces.append(around.sorted { angle($0) < angle($1) })
        }
        return flatMesh(dv, faces, radius)
    }

    /// Every triple of vertices whose three sides all equal the shortest edge.
    /// That is exactly the face list for the tetrahedron, octahedron and icosahedron.
    static func equilateralTriangles(_ v: [SIMD3<Float>]) -> [[Int]] {
        var edge = Float.greatestFiniteMagnitude
        for i in v.indices { for j in v.indices where j > i { edge = min(edge, simd_distance(v[i], v[j])) } }
        let tol = edge * 0.01
        func isEdge(_ a: Int, _ b: Int) -> Bool { abs(simd_distance(v[a], v[b]) - edge) < tol }
        var faces: [[Int]] = []
        for i in v.indices {
            for j in v.indices where j > i && isEdge(i, j) {
                for k in v.indices where k > j && isEdge(i, k) && isEdge(j, k) {
                    faces.append([i, j, k])
                }
            }
        }
        return faces
    }

    /// Flat-shaded mesh: each face gets its own vertices and one outward normal,
    /// so the facets catch light like cut glass.
    static func flatMesh(_ v: [SIMD3<Float>], _ faces: [[Int]], _ radius: Float) -> MeshResource {
        let scale = radius / (v.map { simd_length($0) }.max() ?? 1)
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        for f in faces {
            var pts = f.map { v[$0] * scale }
            let centre = pts.reduce(SIMD3<Float>(repeating: 0), +) / Float(pts.count)
            var n = simd_normalize(simd_cross(pts[1] - pts[0], pts[2] - pts[0]))
            if simd_dot(n, centre) < 0 { n = -n; pts.reverse() }
            let base = UInt32(positions.count)
            for p in pts { positions.append(p); normals.append(n) }
            for k in 1..<(pts.count - 1) {
                indices += [base, base + UInt32(k), base + UInt32(k + 1)]
            }
        }
        var d = MeshDescriptor(name: "chakra-solid")
        d.positions = MeshBuffers.Positions(positions)
        d.normals = MeshBuffers.Normals(normals)
        d.primitives = .triangles(indices)
        return try! MeshResource.generate(from: [d])
    }
}
