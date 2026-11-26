import XCTest
import simd

/// Checks the reconstruction math on synthetic data with known answers.
final class ReconTests: XCTestCase {

    // MARK: TSDF + surface nets

    /// A sphere written straight into the volume comes back as a closed surface within a few millimetres.
    func testSurfaceNetsRecoversSphere() {
        let volume = TSDFVolume(voxelSize: 0.02, truncationVoxels: 3)
        let r: Float = 0.3
        let trunc = volume.truncation
        for z in -22...22 {
            for y in -22...22 {
                for x in -22...22 {
                    let key = SIMD3<Int32>(Int32(x), Int32(y), Int32(z))
                    let c = (SIMD3<Float>(key) + 0.5) * volume.voxelSize
                    let d = simd_length(c) - r
                    guard abs(d) < trunc * 2 else { continue }
                    volume.set(key, value: max(-1, min(1, d / trunc)))
                }
            }
        }
        let mesh = volume.extractSurface()
        XCTAssertGreaterThan(mesh.triangleCount, 2000)
        var worst: Float = 0
        for p in mesh.positions { worst = max(worst, abs(simd_length(p) - r)) }
        XCTAssertLessThan(worst, 0.006, "vertices should lie on the sphere")
        // Normals point outward.
        var outward = 0
        for t in 0..<mesh.triangleCount {
            let (a, b, c) = mesh.triangle(t)
            let centroid = (mesh.positions[a] + mesh.positions[b] + mesh.positions[c]) / 3
            if simd_dot(mesh.faceNormal(t), centroid) > 0 { outward += 1 }
        }
        XCTAssertGreaterThan(Double(outward) / Double(mesh.triangleCount), 0.98)
    }

    /// Fusing depth frames of a flat wall 2 m in front of the camera gives a flat surface at 2 m.
    func testIntegrateFlatWall() {
        let volume = TSDFVolume(voxelSize: 0.02, truncationVoxels: 3)
        let w = 128, h = 96
        let depth = [UInt16](repeating: 2000, count: w * h)
        for k in 0..<6 {
            var pose = matrix_identity_float4x4
            pose.columns.3 = SIMD4(Float(k) * 0.03, Float(k % 2) * 0.02, 0, 1)
            let cam = TSDFVolume.DepthCamera(fx: 100, fy: 100, cx: 64, cy: 48, cameraToWorld: pose)
            volume.integrate(depthMM: depth, confidence: nil, width: w, height: h, camera: cam, stride: 1, minConfidence: 0)
        }
        let mesh = volume.extractSurface()
        XCTAssertGreaterThan(mesh.triangleCount, 100)
        let meanError = mesh.positions.map { abs($0.z + 2) }.reduce(0, +) / Float(mesh.positions.count)
        XCTAssertLessThan(meanError, 0.012)
    }

    // MARK: Simplification

    func testSimplifierKeepsCubeShape() {
        let cube = Self.subdividedCube(n: 16)
        XCTAssertEqual(cube.triangleCount, 6 * 16 * 16 * 2)
        let simple = MeshSimplifier.simplify(cube, targetTriangles: 300)
        XCTAssertLessThanOrEqual(simple.triangleCount, 300)
        XCTAssertGreaterThan(simple.triangleCount, 11)
        for p in simple.positions {
            let m = max(abs(p.x), abs(p.y), abs(p.z))
            XCTAssertEqual(m, 0.5, accuracy: 0.002, "vertices stay on the cube's faces")
        }
        var lo = SIMD3<Float>(repeating: 1), hi = SIMD3<Float>(repeating: -1)
        for p in simple.positions { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        XCTAssertEqual(lo.x, -0.5, accuracy: 0.002)
        XCTAssertEqual(hi.y, 0.5, accuracy: 0.002)
    }

    // MARK: View selection and seam leveling

    func testGridViewSelectionPrefersCoherentPatches() {
        let nu = 10, nv = 10
        var labels: [[Int32]] = []
        var scores: [[Float]] = []
        for c in 0..<(nu * nv) {
            labels.append([0, 1])
            // Photo 0 is a bit better everywhere, except one cell where photo 1 is a bit better.
            scores.append(c == 55 ? [0.9, 1.0] : [1.0, 0.9])
        }
        let result = ViewSelection.solveGrid(labels: labels, scores: scores, nu: nu, nv: nv)
        XCTAssertTrue(result.allSatisfy { $0 == 0 }, "a lone slightly-better cell should follow its neighbours")

        // A strong preference wins over smoothness.
        var strong = scores
        for c in 0..<(nu * nv) where c % nu >= 5 { strong[c] = [0.2, 1.0] }
        let split = ViewSelection.solveGrid(labels: labels, scores: strong, nu: nu, nv: nv)
        XCTAssertEqual(split[0], 0)
        XCTAssertEqual(split[9], 1)
    }

    func testLevelPatchesRemovesOffset() {
        let g = ViewSelection.levelPatches(patchCount: 2, constraints: [(0, 1, SIMD3(repeating: 0.1), 50)])
        let gap = (g[0] - g[1]).x
        XCTAssertEqual(gap, -0.1, accuracy: 0.01)
    }

    // MARK: Atlas packing

    func testAtlasPackingHasNoOverlaps() {
        var rng = SystemRandomNumberGenerator()
        let sizes: [(w: Int, h: Int)] = (0..<400).map { _ in (Int.random(in: 4...300, using: &rng), Int.random(in: 4...300, using: &rng)) }
        let page = 1024
        let (placements, pages) = AtlasPacker.pack(sizes, pageSize: page)
        XCTAssertGreaterThan(pages, 0)
        for i in sizes.indices {
            let a = placements[i]
            XCTAssertLessThanOrEqual(a.x + sizes[i].w, page)
            XCTAssertLessThanOrEqual(a.y + sizes[i].h, page)
            for j in (i + 1)..<sizes.count {
                let b = placements[j]
                guard a.page == b.page else { continue }
                let overlap = a.x < b.x + sizes[j].w && b.x < a.x + sizes[i].w &&
                              a.y < b.y + sizes[j].h && b.y < a.y + sizes[i].h
                XCTAssertFalse(overlap, "charts \(i) and \(j) overlap")
            }
        }
    }

    // MARK: Pose refinement

    /// A camera knocked 2 cm and ~0.8° off its true pose is pulled back by photometric Gauss-Newton.
    func testPoseRefinementRecoversOffset() {
        let cam = PoseMath.Pinhole(fx: 300, fy: 300, cx: 160, cy: 120, width: 320, height: 240)
        func image(_ u: Float, _ v: Float) -> (value: Float, gradient: SIMD2<Float>) {
            let value = 0.5 + 0.25 * sin(u / 9) * cos(v / 7) + 0.15 * sin((u + v) / 13)
            let gu = 0.25 * cos(u / 9) / 9 * cos(v / 7) + 0.15 * cos((u + v) / 13) / 13
            let gv = -0.25 * sin(u / 9) * sin(v / 7) / 7 + 0.15 * cos((u + v) / 13) / 13
            return (value, SIMD2(gu, gv))
        }
        let truth = matrix_identity_float4x4
        var points: [SIMD3<Float>] = []
        for j in 0..<30 {
            for i in 0..<40 {
                let z: Float = (i + j) % 2 == 0 ? -2 : -2.6
                points.append(SIMD3(Float(i) / 39 * 2.4 - 1.2, Float(j) / 29 * 1.6 - 0.8, z) * (-z / 2))
            }
        }
        let targets: [Float] = points.map { p in
            let q = truth * SIMD4(p.x, p.y, p.z, 1)
            let z = -q.z
            return image(cam.fx * q.x / z + cam.cx, -cam.fy * q.y / z + cam.cy).value
        }
        var pose = PoseMath.rigid(rotation: SIMD3(0.01, -0.008, 0.006), translation: SIMD3(0.02, -0.012, 0.008)) * truth
        let (d0, a0) = PoseMath.difference(pose, truth)
        XCTAssertGreaterThan(d0, 0.015)
        for _ in 0..<40 {
            guard let step = PoseMath.gaussNewtonStep(worldToCamera: pose, points: points, targets: targets,
                                                      camera: cam, gain: 1, sample: { image($0, $1) }) else { break }
            pose = step.0
        }
        let (d1, a1) = PoseMath.difference(pose, truth)
        XCTAssertLessThan(d1, 0.003, "translation error \(d1) m (was \(d0))")
        XCTAssertLessThan(a1, 0.15, "rotation error \(a1)° (was \(a0))")
    }

    // MARK: Helpers

    static func subdividedCube(n: Int) -> ReconMesh {
        var mesh = ReconMesh()
        let faces: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = [   // normal, u, v (u × v = normal)
            (SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)),
            (SIMD3(-1, 0, 0), SIMD3(0, 0, 1), SIMD3(0, 1, 0)),
            (SIMD3(0, 1, 0), SIMD3(0, 0, 1), SIMD3(1, 0, 0)),
            (SIMD3(0, -1, 0), SIMD3(1, 0, 0), SIMD3(0, 0, 1)),
            (SIMD3(0, 0, 1), SIMD3(1, 0, 0), SIMD3(0, 1, 0)),
            (SIMD3(0, 0, -1), SIMD3(0, 1, 0), SIMD3(1, 0, 0)),
        ]
        var index: [SIMD3<Int32>: UInt32] = [:]
        func vertex(_ p: SIMD3<Float>) -> UInt32 {
            let q = p * Float(2 * n)
            let key = SIMD3<Int32>(Int32(q.x.rounded()), Int32(q.y.rounded()), Int32(q.z.rounded()))
            if let i = index[key] { return i }
            let i = UInt32(mesh.positions.count)
            mesh.positions.append(p)
            index[key] = i
            return i
        }
        for (normal, u, v) in faces {
            for j in 0..<n {
                for i in 0..<n {
                    func corner(_ a: Int, _ b: Int) -> UInt32 {
                        let s = Float(a) / Float(n) - 0.5, t = Float(b) / Float(n) - 0.5
                        return vertex(normal * 0.5 + u * s + v * t)
                    }
                    let a = corner(i, j), b = corner(i + 1, j), c = corner(i + 1, j + 1), d = corner(i, j + 1)
                    mesh.indices += [a, b, c, a, c, d]
                }
            }
        }
        return mesh
    }
}
