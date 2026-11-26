import Foundation

/// Packs rectangles (texture charts) into square atlas pages with a shelf packer: charts sorted tallest first,
/// placed left to right in rows ("shelves"). Simple, fast and good enough when charts are many and similar.
///
/// Pure math, no ARKit: also compiled into the unit tests.
enum AtlasPacker {
    struct Placement: Equatable {
        var page: Int
        var x: Int
        var y: Int
    }

    /// - Parameters:
    ///   - sizes: width and height of each chart in pixels (including any padding).
    ///   - pageSize: side of a square atlas page.
    /// - Returns: where each chart goes, and the number of pages used. Charts bigger than a page are clamped
    ///   (callers should scale first).
    static func pack(_ sizes: [(w: Int, h: Int)], pageSize: Int) -> (placements: [Placement], pages: Int) {
        let order = sizes.indices.sorted { sizes[$0].h != sizes[$1].h ? sizes[$0].h > sizes[$1].h : sizes[$0].w > sizes[$1].w }
        var placements = [Placement](repeating: Placement(page: 0, x: 0, y: 0), count: sizes.count)
        var page = 0, x = 0, y = 0, shelfHeight = 0
        var used = false
        for i in order {
            let w = min(sizes[i].w, pageSize), h = min(sizes[i].h, pageSize)
            if x + w > pageSize {            // next shelf
                y += shelfHeight
                x = 0
                shelfHeight = 0
            }
            if y + h > pageSize {            // next page
                page += 1
                x = 0
                y = 0
                shelfHeight = 0
            }
            placements[i] = Placement(page: page, x: x, y: y)
            used = true
            x += w
            shelfHeight = max(shelfHeight, h)
        }
        return (placements, used ? page + 1 : 0)
    }
}
