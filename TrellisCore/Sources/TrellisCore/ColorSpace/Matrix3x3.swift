//
//  Matrix3x3.swift
//  TrellisCore
//
//  Created by Ben Colson on 06/10/2026.
//

/// A 3-component RGB or XYZ triple. `SIMD3<Double>` is in the Swift standard
/// library, so this stays portable (no dependency on Apple's `simd` module).
public typealias Vector3 = SIMD3<Double>

/// A row-major 3×3 matrix of `Double`.
///
/// Deliberately tiny and dependency-free: every matrix Trellis uses is derived
/// in code from published primaries (see `RGBPrimaries`), so all we need is
/// multiply, compose and invert.
public struct Matrix3x3: Equatable, Sendable, CustomStringConvertible {
    public var rows: (Vector3, Vector3, Vector3)

    public init(rows r0: Vector3, _ r1: Vector3, _ r2: Vector3) {
        rows = (r0, r1, r2)
    }

    /// Builds a matrix from three column vectors.
    public init(columns c0: Vector3, _ c1: Vector3, _ c2: Vector3) {
        rows = (
            Vector3(c0.x, c1.x, c2.x),
            Vector3(c0.y, c1.y, c2.y),
            Vector3(c0.z, c1.z, c2.z)
        )
    }

    public static let identity = Matrix3x3(rows: [1, 0, 0], [0, 1, 0], [0, 0, 1])

    /// Element at `row`, `column` (both 0-based).
    public subscript(row: Int, column: Int) -> Double {
        let r: Vector3
        switch row {
        case 0: r = rows.0
        case 1: r = rows.1
        case 2: r = rows.2
        default: preconditionFailure("Matrix3x3 row index out of range: \(row)")
        }
        return r[column]
    }

    /// Row-major elements, handy for tests and fixtures.
    public var elements: [Double] {
        [rows.0.x, rows.0.y, rows.0.z,
         rows.1.x, rows.1.y, rows.1.z,
         rows.2.x, rows.2.y, rows.2.z]
    }

    public static func * (m: Matrix3x3, v: Vector3) -> Vector3 {
        Vector3(
            (m.rows.0 * v).sum(),
            (m.rows.1 * v).sum(),
            (m.rows.2 * v).sum()
        )
    }

    public static func * (a: Matrix3x3, b: Matrix3x3) -> Matrix3x3 {
        let bt = b.transposed
        func row(_ r: Vector3) -> Vector3 {
            Vector3((r * bt.rows.0).sum(), (r * bt.rows.1).sum(), (r * bt.rows.2).sum())
        }
        return Matrix3x3(rows: row(a.rows.0), row(a.rows.1), row(a.rows.2))
    }

    public var transposed: Matrix3x3 {
        Matrix3x3(columns: rows.0, rows.1, rows.2)
    }

    public var determinant: Double {
        let (a, b, c) = rows
        return a.x * (b.y * c.z - b.z * c.y)
             - a.y * (b.x * c.z - b.z * c.x)
             + a.z * (b.x * c.y - b.y * c.x)
    }

    /// Inverse via the adjugate. Returns `nil` for a (near-)singular matrix.
    public var inverse: Matrix3x3? {
        let det = determinant
        guard abs(det) > 1e-12 else { return nil }
        let (a, b, c) = rows
        // Rows of the inverse are the cross products of the columns' complements.
        let r0 = Vector3(b.y * c.z - b.z * c.y, a.z * c.y - a.y * c.z, a.y * b.z - a.z * b.y)
        let r1 = Vector3(b.z * c.x - b.x * c.z, a.x * c.z - a.z * c.x, a.z * b.x - a.x * b.z)
        let r2 = Vector3(b.x * c.y - b.y * c.x, a.y * c.x - a.x * c.y, a.x * b.y - a.y * b.x)
        return Matrix3x3(rows: r0 / det, r1 / det, r2 / det)
    }

    public static func == (lhs: Matrix3x3, rhs: Matrix3x3) -> Bool {
        lhs.elements == rhs.elements
    }

    public var description: String {
        func fmt(_ v: Vector3) -> String { "[\(v.x), \(v.y), \(v.z)]" }
        return "[\(fmt(rows.0)), \(fmt(rows.1)), \(fmt(rows.2))]"
    }
}
