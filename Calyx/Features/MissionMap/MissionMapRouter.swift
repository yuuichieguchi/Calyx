// MissionMapRouter.swift
// Calyx
//
// Orthogonal edge routing for Mission Map's lines (IPC and conflict
// alike), in the manner of libavoid: an orthogonal visibility graph over
// a sparse grid, A* per edge with a bend penalty, then nudging so lines
// that share a channel run on separate, evenly spaced tracks. It works on
// any arrangement of rectangles -- a laid-out map and a map with dragged,
// even overlapping, cards go through the same steps. Pure geometry.
//
// 1. Grid. Every obstacle is inflated by `obstacleMargin` (its ring).
//    Grid lines run along every ring edge, every rectangle's center lines
//    (where the side-midpoint ports' stubs end) and the bounds' edges.
//    Nodes strictly inside a ring or outside `bounds` are removed, as are
//    grid edges crossing a ring's interior; running along a ring's
//    boundary is allowed.
// 2. Ports. Each card has a port at the midpoint of each side, plus, for
//    each edge whose two cards' projections overlap, a port on each
//    facing side at the middle of the overlap (so cards of different
//    heights still get a straight line). A port leaves its card
//    through a short stub, straight out to the grid node on its own ring. The stub may cross its own ring (that is the point
//    of it), but a port whose stub would enter another ring, or ends on a
//    removed node, is unusable.
// 3. A*. For each edge, from any usable port of `from` to any usable port
//    of `to`; cost = length + `bendPenalty` per change of direction, with
//    the direction kept in the search state so bends are counted exactly;
//    heuristic = Manhattan distance to the nearest target port; ties are
//    broken by f, g, then grid x, then grid y. Edges are routed
//    independently, in `id.uuidString` order.
// 4. Simplify. Collinear consecutive segments merge, so a route's
//    segments alternate between horizontal and vertical.
// 5. Nudge. Segments of different edges on the same axis and coordinate
//    whose ranges overlap form a group (transitively). Each group gets
//    one track per edge, ordered by where the routes part (so they do
//    not cross; edge id when they never part), `trackSpacing` apart and
//    kept inside the group's free channel -- the space between the
//    nearest rings (or bounds) on either side; tracks spread evenly
//    across the channel, touching both limits, when they do not fit.
//    Moving a segment drags the ends of its perpendicular neighbours
//    along; a route's end segment carries its port along the card side
//    (and is kept on that side). If nudging lands two groups on top of
//    each other, the groups merge and are placed again as one.

import CoreGraphics
import Foundation

/// One line to route: from one card's rectangle to another's.
struct MissionMapRouteRequest: Hashable, Sendable {
    let id: UUID
    let from: CGRect
    let to: CGRect
}

struct MissionMapRouterOptions: Hashable, Sendable {
    /// How far each obstacle is inflated: lines keep at least this far
    /// from any card (except where they leave or enter their own).
    let obstacleMargin: CGFloat
    /// The distance between parallel lines sharing a channel.
    let trackSpacing: CGFloat
    /// The cost of one change of direction, in points of length.
    let bendPenalty: CGFloat

    init(obstacleMargin: CGFloat = 6, trackSpacing: CGFloat = 8, bendPenalty: CGFloat = 40) {
        self.obstacleMargin = obstacleMargin
        self.trackSpacing = trackSpacing
        self.bendPenalty = bendPenalty
    }

    static let `default` = MissionMapRouterOptions()
}

enum MissionMapRouter {

    /// The distance under which two coordinates count as the same.
    fileprivate static let tolerance: CGFloat = 0.001

    /// Every request's route, keyed by request id: an orthogonal polyline
    /// (at least 2 points, segments alternating axis) from a point on
    /// `from`'s border to a point on `to`'s, avoiding every rectangle in
    /// `obstacles` and staying inside `bounds`. When no such path exists
    /// (the cards overlap, or every port is walled in) the route is the
    /// straight segment between the two borders along the line joining
    /// the centers (`MissionMapLayout.edgeAnchors`) -- the line is still
    /// drawn, just not routed; such a route takes no part in nudging.
    static func route(
        _ requests: [MissionMapRouteRequest], obstacles: [CGRect], bounds: CGRect,
        options: MissionMapRouterOptions = .default
    ) -> [UUID: [CGPoint]] {
        let margin = options.obstacleMargin
        let rings = obstacles.map { $0.insetBy(dx: -margin, dy: -margin) }
        let grid = RoutingGrid(
            rings: rings, bounds: bounds,
            portRects: obstacles + requests.flatMap { [$0.from, $0.to] },
            facingPorts: requests.flatMap { FacingPorts.between($0.from, $0.to).all },
            margin: margin
        )
        var search = SearchWorkspace(stateCount: grid.nodeCount * 2)

        var result: [UUID: [CGPoint]] = [:]
        var routed: [RoutedEdge] = []
        for request in requests.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            let facing = FacingPorts.between(request.from, request.to)
            let sources = grid.usablePorts(of: request.from, extra: facing.from)
            let targets = grid.usablePorts(of: request.to, extra: facing.to)
            if let points = grid.shortestPath(
                from: sources, to: targets, bendPenalty: options.bendPenalty, workspace: &search
            ) {
                routed.append(RoutedEdge(request: request, points: points))
            } else {
                let (a, b) = MissionMapLayout.edgeAnchors(from: request.from, to: request.to)
                result[request.id] = [a, b]
            }
        }

        let nudged = Nudger(routes: routed, rings: rings, bounds: bounds, trackSpacing: options.trackSpacing).run()
        for (edge, points) in zip(routed, nudged) {
            result[edge.request.id] = points
        }
        return result
    }

    /// `points` with duplicate consecutive points removed and collinear
    /// consecutive segments merged.
    fileprivate static func simplify(_ points: [CGPoint]) -> [CGPoint] {
        var out: [CGPoint] = []
        out.reserveCapacity(points.count)
        for point in points {
            out.append(point)
            var changed = true
            while changed {
                changed = false
                let n = out.count
                if n >= 2, same(out[n - 2], out[n - 1]) {
                    out.removeLast()
                    changed = true
                } else if n >= 3 {
                    let a = out[n - 3], b = out[n - 2], c = out[n - 1]
                    let vertical = abs(a.x - b.x) <= tolerance && abs(b.x - c.x) <= tolerance
                    let horizontal = abs(a.y - b.y) <= tolerance && abs(b.y - c.y) <= tolerance
                    if vertical || horizontal {
                        out.remove(at: n - 2)
                        changed = true
                    }
                }
            }
        }
        return out
    }

    private static func same(_ a: CGPoint, _ b: CGPoint) -> Bool {
        abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
    }
}

// MARK: - Cache

/// Remembers the last routing so a redraw with unchanged input (the 30 fps
/// pulse timeline, a re-render caused by something unrelated) does not
/// route again. One entry: while a card is dragged the input changes every
/// frame anyway, and only the latest result is ever needed.
@MainActor
final class MissionMapRouteCache {
    private struct Input: Equatable {
        let requests: [MissionMapRouteRequest]
        let obstacles: [CGRect]
        let bounds: CGRect
        let options: MissionMapRouterOptions
    }

    private var last: (input: Input, routes: [UUID: [CGPoint]])?

    func routes(
        _ requests: [MissionMapRouteRequest], obstacles: [CGRect], bounds: CGRect,
        options: MissionMapRouterOptions = .default
    ) -> [UUID: [CGPoint]] {
        let input = Input(requests: requests, obstacles: obstacles, bounds: bounds, options: options)
        if let last, last.input == input {
            return last.routes
        }
        let routes = MissionMapRouter.route(requests, obstacles: obstacles, bounds: bounds, options: options)
        last = (input, routes)
        return routes
    }
}

// MARK: - Grid

private enum Axis: Int {
    case horizontal = 0
    case vertical = 1
}

/// A side-midpoint port that can be used: the point on the card's border,
/// the grid node its stub ends on, and the stub's direction.
private struct Port {
    let point: CGPoint
    let stubEnd: CGPoint
    let node: Int
    let axis: Axis

    var stubLength: CGFloat { abs(stubEnd.x - point.x) + abs(stubEnd.y - point.y) }
}

/// A place on a card's border a line may leave or enter through: the
/// point, and the side's outward direction.
private struct PortCandidate {
    let point: CGPoint
    /// Outward unit direction of the side: (-1, 0) left, (1, 0) right,
    /// (0, -1) top, (0, 1) bottom.
    let outwardX: CGFloat
    let outwardY: CGFloat

    var axis: Axis { outwardX != 0 ? .horizontal : .vertical }

    /// Where the port's stub meets the card's ring.
    func stubEnd(margin: CGFloat) -> CGPoint {
        CGPoint(x: point.x + outwardX * margin, y: point.y + outwardY * margin)
    }

    static func sideMidpoints(of rect: CGRect) -> [PortCandidate] {
        [
            PortCandidate(point: CGPoint(x: rect.minX, y: rect.midY), outwardX: -1, outwardY: 0),
            PortCandidate(point: CGPoint(x: rect.maxX, y: rect.midY), outwardX: 1, outwardY: 0),
            PortCandidate(point: CGPoint(x: rect.midX, y: rect.minY), outwardX: 0, outwardY: -1),
            PortCandidate(point: CGPoint(x: rect.midX, y: rect.maxY), outwardX: 0, outwardY: 1),
        ]
    }
}

/// Ports on the facing sides of two cards whose projections overlap, at
/// the middle of the overlap, so a straight, bend-free line is possible
/// between cards of different heights (or widths) -- side midpoints alone
/// would force a jog.
private struct FacingPorts {
    let from: [PortCandidate]
    let to: [PortCandidate]

    var all: [PortCandidate] { from + to }

    static func between(_ a: CGRect, _ b: CGRect) -> FacingPorts {
        let tol = MissionMapRouter.tolerance
        var fromPorts: [PortCandidate] = []
        var toPorts: [PortCandidate] = []
        let overlapTop = max(a.minY, b.minY)
        let overlapBottom = min(a.maxY, b.maxY)
        if overlapBottom - overlapTop > tol {
            let y = (overlapTop + overlapBottom) / 2
            if a.maxX <= b.minX + tol {
                fromPorts.append(PortCandidate(point: CGPoint(x: a.maxX, y: y), outwardX: 1, outwardY: 0))
                toPorts.append(PortCandidate(point: CGPoint(x: b.minX, y: y), outwardX: -1, outwardY: 0))
            } else if b.maxX <= a.minX + tol {
                fromPorts.append(PortCandidate(point: CGPoint(x: a.minX, y: y), outwardX: -1, outwardY: 0))
                toPorts.append(PortCandidate(point: CGPoint(x: b.maxX, y: y), outwardX: 1, outwardY: 0))
            }
        }
        let overlapLeft = max(a.minX, b.minX)
        let overlapRight = min(a.maxX, b.maxX)
        if overlapRight - overlapLeft > tol {
            let x = (overlapLeft + overlapRight) / 2
            if a.maxY <= b.minY + tol {
                fromPorts.append(PortCandidate(point: CGPoint(x: x, y: a.maxY), outwardX: 0, outwardY: 1))
                toPorts.append(PortCandidate(point: CGPoint(x: x, y: b.minY), outwardX: 0, outwardY: -1))
            } else if b.maxY <= a.minY + tol {
                fromPorts.append(PortCandidate(point: CGPoint(x: x, y: a.minY), outwardX: 0, outwardY: -1))
                toPorts.append(PortCandidate(point: CGPoint(x: x, y: b.maxY), outwardX: 0, outwardY: 1))
            }
        }
        return FacingPorts(from: fromPorts, to: toPorts)
    }
}

private struct RoutedEdge {
    let request: MissionMapRouteRequest
    let points: [CGPoint]
}

private struct RoutingGrid {
    let xs: [CGFloat]
    let ys: [CGFloat]
    let nx: Int
    let ny: Int
    let rings: [CGRect]
    let bounds: CGRect
    let margin: CGFloat
    /// Per node (`j * nx + i`): strictly inside a ring.
    private(set) var nodeBlocked: [Bool]
    /// Per node: the edge to its right neighbour crosses a ring.
    private(set) var rightBlocked: [Bool]
    /// Per node: the edge to its lower neighbour crosses a ring.
    private(set) var downBlocked: [Bool]

    var nodeCount: Int { nx * ny }

    init(rings: [CGRect], bounds: CGRect, portRects: [CGRect], facingPorts: [PortCandidate], margin: CGFloat) {
        self.rings = rings
        self.bounds = bounds
        self.margin = margin
        var xValues: [CGFloat] = [bounds.minX, bounds.maxX]
        var yValues: [CGFloat] = [bounds.minY, bounds.maxY]
        xValues.reserveCapacity(rings.count * 2 + portRects.count * 3 + 2)
        yValues.reserveCapacity(rings.count * 2 + portRects.count * 3 + 2)
        for ring in rings {
            xValues.append(ring.minX)
            xValues.append(ring.maxX)
            yValues.append(ring.minY)
            yValues.append(ring.maxY)
        }
        for rect in portRects {
            // Where the four ports' stubs end: the center lines, and the
            // rect's own ring edges (also present when the rect is not an
            // obstacle).
            xValues.append(rect.midX)
            xValues.append(rect.minX - margin)
            xValues.append(rect.maxX + margin)
            yValues.append(rect.midY)
            yValues.append(rect.minY - margin)
            yValues.append(rect.maxY + margin)
        }
        for candidate in facingPorts {
            xValues.append(candidate.stubEnd(margin: margin).x)
            yValues.append(candidate.stubEnd(margin: margin).y)
        }
        xs = Self.coordinates(xValues, within: bounds.minX, bounds.maxX)
        ys = Self.coordinates(yValues, within: bounds.minY, bounds.maxY)
        nx = xs.count
        ny = ys.count

        let count = nx * ny
        nodeBlocked = Array(repeating: false, count: count)
        rightBlocked = Array(repeating: false, count: count)
        downBlocked = Array(repeating: false, count: count)
        let tol = MissionMapRouter.tolerance
        for ring in rings {
            // Grid lines strictly inside the ring, and the runs of grid
            // intervals the ring covers.
            let insideX = Self.lowerBound(xs, ring.minX + tol)..<Self.lowerBound(xs, ring.maxX - tol)
            let insideY = Self.lowerBound(ys, ring.minY + tol)..<Self.lowerBound(ys, ring.maxY - tol)
            let coveredX = Self.lowerBound(xs, ring.minX - tol)..<(Self.lowerBound(xs, ring.maxX + tol) - 1)
            let coveredY = Self.lowerBound(ys, ring.minY - tol)..<(Self.lowerBound(ys, ring.maxY + tol) - 1)
            for j in insideY {
                for i in insideX {
                    nodeBlocked[j * nx + i] = true
                }
                if !coveredX.isEmpty {
                    for i in coveredX {
                        rightBlocked[j * nx + i] = true
                    }
                }
            }
            if !coveredY.isEmpty {
                for j in coveredY {
                    for i in insideX {
                        downBlocked[j * nx + i] = true
                    }
                }
            }
        }
    }

    /// `values` inside `lo...hi`, sorted, with near-duplicates collapsed.
    private static func coordinates(_ values: [CGFloat], within lo: CGFloat, _ hi: CGFloat) -> [CGFloat] {
        let tol = MissionMapRouter.tolerance
        let sorted = values
            .filter { $0 >= lo - tol && $0 <= hi + tol }
            .map { min(max($0, lo), hi) }
            .sorted()
        var out: [CGFloat] = []
        out.reserveCapacity(sorted.count)
        for value in sorted {
            if let last = out.last, value - last <= tol { continue }
            out.append(value)
        }
        return out
    }

    /// The first index whose value is `>= value`.
    private static func lowerBound(_ array: [CGFloat], _ value: CGFloat) -> Int {
        var lo = 0
        var hi = array.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if array[mid] < value { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    private static func index(of value: CGFloat, in array: [CGFloat]) -> Int? {
        let tol = MissionMapRouter.tolerance
        let k = lowerBound(array, value - tol)
        guard k < array.count, abs(array[k] - value) <= tol else { return nil }
        return k
    }

    func point(of node: Int) -> CGPoint {
        CGPoint(x: xs[node % nx], y: ys[node / nx])
    }

    /// The usable ports of `rect`: its four side midpoints (left, right,
    /// top, bottom), then `extra`.
    func usablePorts(of rect: CGRect, extra: [PortCandidate]) -> [Port] {
        let ownRing = rect.insetBy(dx: -margin, dy: -margin)
        let candidates = PortCandidate.sideMidpoints(of: rect) + extra
        var ports: [Port] = []
        for candidate in candidates {
            let point = candidate.point
            let stubEnd = candidate.stubEnd(margin: margin)
            guard let i = Self.index(of: stubEnd.x, in: xs), let j = Self.index(of: stubEnd.y, in: ys) else {
                continue // outside bounds
            }
            let node = j * nx + i
            guard !nodeBlocked[node], !stubEntersForeignRing(from: point, to: stubEnd, ownRing: ownRing) else {
                continue
            }
            guard !ports.contains(where: { $0.node == node }) else { continue }
            ports.append(Port(point: point, stubEnd: stubEnd, node: node, axis: candidate.axis))
        }
        return ports
    }

    private func stubEntersForeignRing(from a: CGPoint, to b: CGPoint, ownRing: CGRect) -> Bool {
        let tol = MissionMapRouter.tolerance
        for ring in rings where !Self.sameRect(ring, ownRing) {
            if Self.segment(a, b, entersInteriorOf: ring, tolerance: tol) { return true }
        }
        return false
    }

    private static func sameRect(_ r1: CGRect, _ r2: CGRect) -> Bool {
        let tol = MissionMapRouter.tolerance
        return abs(r1.minX - r2.minX) <= tol && abs(r1.minY - r2.minY) <= tol
            && abs(r1.maxX - r2.maxX) <= tol && abs(r1.maxY - r2.maxY) <= tol
    }

    /// Whether the axis-aligned segment `a`-`b` has positive-length overlap
    /// with the open interior of `rect`.
    fileprivate static func segment(_ a: CGPoint, _ b: CGPoint, entersInteriorOf rect: CGRect, tolerance tol: CGFloat) -> Bool {
        if abs(a.y - b.y) <= tol {
            let y = a.y
            guard y > rect.minY + tol, y < rect.maxY - tol else { return false }
            return max(min(a.x, b.x), rect.minX) < min(max(a.x, b.x), rect.maxX) - tol
        } else {
            let x = a.x
            guard x > rect.minX + tol, x < rect.maxX - tol else { return false }
            return max(min(a.y, b.y), rect.minY) < min(max(a.y, b.y), rect.maxY) - tol
        }
    }

    // MARK: A*

    /// The cheapest orthogonal path from any of `sources` to any of
    /// `targets` (port to port, simplified), or nil when none exists.
    func shortestPath(
        from sources: [Port], to targets: [Port], bendPenalty: CGFloat, workspace w: inout SearchWorkspace
    ) -> [CGPoint]? {
        guard !sources.isEmpty, !targets.isEmpty else { return nil }
        w.begin()
        let targetXs = targets.map(\.point.x)
        let targetYs = targets.map(\.point.y)
        func heuristic(_ node: Int) -> CGFloat {
            let x = xs[node % nx]
            let y = ys[node / nx]
            var best = CGFloat.infinity
            for k in 0..<targetXs.count {
                best = min(best, abs(x - targetXs[k]) + abs(y - targetYs[k]))
            }
            return best
        }

        for port in sources {
            let state = port.node * 2 + port.axis.rawValue
            let g = port.stubLength
            if w.relax(state, g: g, parent: -1) {
                w.push(HeapEntry(f: g + heuristic(port.node), g: g, i: Int32(port.node % nx), j: Int32(port.node / nx),
                                 axis: Int8(port.axis.rawValue), state: Int32(state), goal: -1))
            }
        }

        while let entry = w.pop() {
            if entry.goal >= 0 {
                let points = reconstruct(goal: Int(entry.goal), lastState: Int(entry.state), sources: sources, targets: targets, workspace: w)
                // `from` and `to` sharing a port (identical rects) collapse
                // to a single point: there is no line to route.
                return points.count >= 2 ? points : nil
            }
            let state = Int(entry.state)
            guard !w.isClosed(state), entry.g <= w.g(state) else { continue }
            w.close(state)
            let node = state >> 1
            let axis = state & 1

            for (t, target) in targets.enumerated() where target.node == node {
                let total = entry.g + target.stubLength + (axis == target.axis.rawValue ? 0 : bendPenalty)
                w.push(HeapEntry(f: total, g: total, i: -1, j: Int32(t), axis: 0, state: Int32(state), goal: Int32(t)))
            }

            let i = node % nx
            let j = node / nx
            // Right, left, down, up.
            if i + 1 < nx, !rightBlocked[node] {
                expand(to: node + 1, axis: 0, length: xs[i + 1] - xs[i], from: entry, fromAxis: axis, bendPenalty: bendPenalty, heuristic: heuristic, workspace: &w)
            }
            if i > 0, !rightBlocked[node - 1] {
                expand(to: node - 1, axis: 0, length: xs[i] - xs[i - 1], from: entry, fromAxis: axis, bendPenalty: bendPenalty, heuristic: heuristic, workspace: &w)
            }
            if j + 1 < ny, !downBlocked[node] {
                expand(to: node + nx, axis: 1, length: ys[j + 1] - ys[j], from: entry, fromAxis: axis, bendPenalty: bendPenalty, heuristic: heuristic, workspace: &w)
            }
            if j > 0, !downBlocked[node - nx] {
                expand(to: node - nx, axis: 1, length: ys[j] - ys[j - 1], from: entry, fromAxis: axis, bendPenalty: bendPenalty, heuristic: heuristic, workspace: &w)
            }
        }
        return nil
    }

    private func expand(
        to neighbor: Int, axis: Int, length: CGFloat, from entry: HeapEntry, fromAxis: Int, bendPenalty: CGFloat,
        heuristic: (Int) -> CGFloat, workspace w: inout SearchWorkspace
    ) {
        guard !nodeBlocked[neighbor] else { return }
        let state = neighbor * 2 + axis
        guard !w.isClosed(state) else { return }
        let g = entry.g + length + (axis == fromAxis ? 0 : bendPenalty)
        guard w.relax(state, g: g, parent: Int(entry.state)) else { return }
        w.push(HeapEntry(f: g + heuristic(neighbor), g: g, i: Int32(neighbor % nx), j: Int32(neighbor / nx),
                         axis: Int8(axis), state: Int32(state), goal: -1))
    }

    private func reconstruct(goal: Int, lastState: Int, sources: [Port], targets: [Port], workspace w: SearchWorkspace) -> [CGPoint] {
        var states: [Int] = []
        var state = lastState
        while state >= 0 {
            states.append(state)
            state = w.parent(state)
        }
        states.reverse()
        let firstState = states[0]
        // Seeded states are exactly the sources' (node, axis) pairs.
        let source = sources.first { $0.node * 2 + $0.axis.rawValue == firstState }
        var points: [CGPoint] = []
        points.reserveCapacity(states.count + 2)
        if let source { points.append(source.point) }
        for s in states { points.append(point(of: s >> 1)) }
        points.append(targets[goal].point)
        return MissionMapRouter.simplify(points)
    }
}

// MARK: - A* workspace

private struct HeapEntry {
    let f: CGFloat
    let g: CGFloat
    let i: Int32
    let j: Int32
    let axis: Int8
    let state: Int32
    /// The target index for a goal entry (reached `targets[goal]`'s port
    /// from `state`), -1 for an ordinary search state.
    let goal: Int32

    /// Deterministic order: f, then g, then grid x, then grid y.
    static func precedes(_ a: HeapEntry, _ b: HeapEntry) -> Bool {
        if a.f != b.f { return a.f < b.f }
        if a.g != b.g { return a.g < b.g }
        if a.i != b.i { return a.i < b.i }
        if a.j != b.j { return a.j < b.j }
        return a.axis < b.axis
    }
}

/// A* bookkeeping reused across the requests of one `route` call; a
/// generation stamp invalidates the previous search instead of clearing
/// the arrays.
private struct SearchWorkspace {
    private var gScore: [CGFloat]
    private var parents: [Int32]
    private var seen: [Int32]
    private var closed: [Int32]
    private var generation: Int32 = 0
    private var heap: [HeapEntry] = []

    init(stateCount: Int) {
        gScore = Array(repeating: 0, count: stateCount)
        parents = Array(repeating: -1, count: stateCount)
        seen = Array(repeating: 0, count: stateCount)
        closed = Array(repeating: 0, count: stateCount)
    }

    mutating func begin() {
        generation += 1
        heap.removeAll(keepingCapacity: true)
    }

    func g(_ state: Int) -> CGFloat { seen[state] == generation ? gScore[state] : .infinity }
    func parent(_ state: Int) -> Int { Int(parents[state]) }
    func isClosed(_ state: Int) -> Bool { closed[state] == generation }
    mutating func close(_ state: Int) { closed[state] = generation }

    /// Records `g` for `state` if it improves on the known cost.
    mutating func relax(_ state: Int, g: CGFloat, parent: Int) -> Bool {
        guard g < self.g(state) else { return false }
        gScore[state] = g
        parents[state] = Int32(parent)
        seen[state] = generation
        return true
    }

    mutating func push(_ entry: HeapEntry) {
        heap.append(entry)
        var child = heap.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard HeapEntry.precedes(heap[child], heap[parent]) else { break }
            heap.swapAt(child, parent)
            child = parent
        }
    }

    mutating func pop() -> HeapEntry? {
        guard !heap.isEmpty else { return nil }
        let top = heap[0]
        let last = heap.removeLast()
        guard !heap.isEmpty else { return top }
        heap[0] = last
        var parent = 0
        let count = heap.count
        while true {
            let left = parent * 2 + 1
            let right = left + 1
            var best = parent
            if left < count, HeapEntry.precedes(heap[left], heap[best]) { best = left }
            if right < count, HeapEntry.precedes(heap[right], heap[best]) { best = right }
            guard best != parent else { break }
            heap.swapAt(parent, best)
            parent = best
        }
        return top
    }
}

// MARK: - Nudging

private struct Nudger {
    let routes: [RoutedEdge]
    let rings: [CGRect]
    let bounds: CGRect
    let trackSpacing: CGFloat

    /// One segment of one route, with the free channel it may move in.
    private struct Segment {
        let route: Int
        let index: Int
        let horizontal: Bool
        /// The fixed coordinate: y for a horizontal segment, x for a
        /// vertical one.
        let coord: CGFloat
        /// The extent along the segment's own axis.
        let lo: CGFloat
        let hi: CGFloat
        /// Where the segment may move to (perpendicular to itself).
        let limitLo: CGFloat
        let limitHi: CGFloat
        /// Whether `limitLo` / `limitHi` come from a ring (a real channel
        /// wall) rather than from the bounds.
        let walledLo: Bool
        let walledHi: Bool
        /// The route's first or last segment, attached to a port.
        let terminal: Bool
    }

    func run() -> [[CGPoint]] {
        let tol = MissionMapRouter.tolerance
        var segments: [Segment] = []
        var segmentsOfRoute: [[Int]] = []
        for (r, edge) in routes.enumerated() {
            var indices: [Int] = []
            let points = edge.points
            for k in 0..<(points.count - 1) {
                indices.append(segments.count)
                segments.append(makeSegment(route: r, index: k, points: points, request: edge.request))
            }
            segmentsOfRoute.append(indices)
        }

        // Initial groups: same axis and coordinate, overlapping ranges.
        var groups = UnionFind(count: segments.count)
        let order = segments.indices.sorted { a, b in
            let s = segments[a], t = segments[b]
            if s.horizontal != t.horizontal { return s.horizontal }
            if s.coord != t.coord { return s.coord < t.coord }
            return s.lo < t.lo
        }
        var runStart = 0
        while runStart < order.count {
            var runEnd = runStart + 1
            let first = segments[order[runStart]]
            while runEnd < order.count {
                let next = segments[order[runEnd]]
                guard next.horizontal == first.horizontal, abs(next.coord - first.coord) <= tol else { break }
                runEnd += 1
            }
            // Within one coordinate, sorted by `lo`: sweep overlaps.
            var reach = first.hi
            if runEnd - runStart > 1 {
                for k in (runStart + 1)..<runEnd {
                    let s = segments[order[k]]
                    if s.lo < reach - tol {
                        groups.union(order[k], order[k - 1])
                        reach = max(reach, s.hi)
                    } else {
                        reach = s.hi
                    }
                }
            }
            runStart = runEnd
        }

        // Place, then merge groups whose tracks collide and place again,
        // until no two routes share a coordinate over an overlapping range.
        var position = segments.map(\.coord)
        var nudgedPoints: [[CGPoint]] = []
        while true {
            position = place(segments: segments, groups: &groups)
            nudgedPoints = routes.indices.map { r in
                rebuild(points: routes[r].points, segmentIndices: segmentsOfRoute[r], position: position, segments: segments)
            }
            let merged = mergeCollisions(
                segments: segments, segmentsOfRoute: segmentsOfRoute, points: nudgedPoints, groups: &groups
            )
            if !merged { break }
        }
        return nudgedPoints.map(MissionMapRouter.simplify)
    }

    private func makeSegment(route: Int, index k: Int, points: [CGPoint], request: MissionMapRouteRequest) -> Segment {
        let tol = MissionMapRouter.tolerance
        let a = points[k]
        let b = points[k + 1]
        let horizontal = abs(a.y - b.y) <= tol
        let coord = horizontal ? a.y : a.x
        let lo = horizontal ? min(a.x, b.x) : min(a.y, b.y)
        let hi = horizontal ? max(a.x, b.x) : max(a.y, b.y)

        var limitLo = horizontal ? bounds.minY : bounds.minX
        var limitHi = horizontal ? bounds.maxY : bounds.maxX
        var walledLo = false
        var walledHi = false
        for ring in rings {
            let alongMin = horizontal ? ring.minX : ring.minY
            let alongMax = horizontal ? ring.maxX : ring.maxY
            guard alongMin < hi - tol, alongMax > lo + tol else { continue }
            let perpMin = horizontal ? ring.minY : ring.minX
            let perpMax = horizontal ? ring.maxY : ring.maxX
            if perpMax <= coord + tol {
                if perpMax >= limitLo { limitLo = perpMax; walledLo = true }
            } else if perpMin >= coord - tol {
                if perpMin <= limitHi { limitHi = perpMin; walledHi = true }
            }
            // A ring the segment runs through is its own card's, crossed
            // by the port stub: it does not bound the channel.
        }

        let isFirst = k == 0
        let isLast = k == points.count - 2
        // An end segment carries its port along the card side: keep it
        // on that side.
        for (isEnd, rect) in [(isFirst, request.from), (isLast, request.to)] where isEnd {
            let sideMin = horizontal ? rect.minY : rect.minX
            let sideMax = horizontal ? rect.maxY : rect.maxX
            limitLo = max(limitLo, sideMin)
            limitHi = min(limitHi, sideMax)
        }
        return Segment(
            route: route, index: k, horizontal: horizontal, coord: coord, lo: lo, hi: hi,
            limitLo: limitLo, limitHi: limitHi, walledLo: walledLo, walledHi: walledHi,
            terminal: isFirst || isLast
        )
    }

    /// Every segment's nudged coordinate.
    private func place(segments: [Segment], groups: inout UnionFind) -> [CGFloat] {
        var members: [Int: [Int]] = [:]
        for s in segments.indices {
            members[groups.find(s), default: []].append(s)
        }
        var position = segments.map(\.coord)
        for (_, group) in members {
            let segs = group.map { segments[$0] }
            var lo = segs[0].limitLo
            var hi = segs[0].limitHi
            var minCoord = segs[0].coord
            var maxCoord = segs[0].coord
            // One track per route; a route's own segments share it.
            var representatives: [Segment] = []
            for s in segs {
                lo = max(lo, s.limitLo)
                hi = min(hi, s.limitHi)
                minCoord = min(minCoord, s.coord)
                maxCoord = max(maxCoord, s.coord)
                if !representatives.contains(where: { $0.route == s.route }) {
                    representatives.append(s)
                }
            }
            // Members were merged only when their channels intersect, so
            // this holds; were it ever violated, the group stays unmoved
            // rather than being pushed out of a channel.
            guard hi >= lo else { continue }

            // Tracks ordered so the routes do not cross (see
            // `precedes`). Insertion sort: deterministic for any group
            // order, and groups are small.
            representatives.sort { routes[$0.route].request.id.uuidString < routes[$1.route].request.id.uuidString }
            var ordered: [Segment] = []
            for candidate in representatives {
                let slot = ordered.firstIndex { precedes(candidate, $0) } ?? ordered.count
                ordered.insert(candidate, at: slot)
            }
            let routeOrder = ordered.map(\.route)
            let n = routeOrder.count

            // Tracks centre on the channel between two walls; a group with
            // a port-attached segment, or open on one side, centres on its
            // own coordinate instead (keeping ports at their side's middle
            // and lines near the card they run along).
            let walled = segs.contains(where: \.walledLo) && segs.contains(where: \.walledHi)
            let terminal = segs.contains(where: \.terminal)
            let center = (!terminal && walled) ? (lo + hi) / 2 : (minCoord + maxCoord) / 2

            var trackOf: [Int: CGFloat] = [:]
            let width = CGFloat(n - 1) * trackSpacing
            if n > 1, width > hi - lo {
                let step = (hi - lo) / CGFloat(n - 1)
                for (k, r) in routeOrder.enumerated() { trackOf[r] = lo + CGFloat(k) * step }
            } else {
                let start = min(max(center - width / 2, lo), hi - width)
                for (k, r) in routeOrder.enumerated() { trackOf[r] = start + CGFloat(k) * trackSpacing }
            }
            for s in group {
                if let track = trackOf[segments[s].route] { position[s] = track }
            }
        }
        return position
    }

    // MARK: Track order

    /// A unit direction along one axis.
    private struct Direction: Equatable {
        let dx: Int
        let dy: Int

        /// The left-hand side of travel in screen coordinates (y down):
        /// travelling +x, left is -y.
        var left: Direction { Direction(dx: dy, dy: -dx) }
        var reversed: Direction { Direction(dx: -dx, dy: -dy) }

        init(dx: Int, dy: Int) {
            self.dx = dx
            self.dy = dy
        }

        init(from a: CGPoint, to b: CGPoint) {
            if abs(b.x - a.x) > MissionMapRouter.tolerance {
                self.init(dx: b.x > a.x ? 1 : -1, dy: 0)
            } else {
                self.init(dx: 0, dy: b.y > a.y ? 1 : -1)
            }
        }
    }

    /// Whether `a`'s track comes before `b`'s (smaller coordinate) in
    /// their shared group, chosen so the two routes do not cross.
    ///
    /// Two routes running side by side keep the same left/right relation
    /// relative to their direction of travel all along the stretch they
    /// share, through every bend. So the relation is read where they
    /// part: walking from the group's low end (then, if undecided, its
    /// high end), a route turning to the left of travel belongs on the
    /// left, and so does a route that turns left where the other ends;
    /// when both turn the same way, the one that goes farther belongs on
    /// that side (outside); when both go equally far, the walk
    /// continues along the next segment. Routes that never part (the same
    /// path, e.g. a round trip) are ordered by edge id, relative to the
    /// travel direction of the lower-id route, so every group they share
    /// agrees.
    private func precedes(_ a: Segment, _ b: Segment) -> Bool {
        let canonical = a.horizontal ? Direction(dx: 1, dy: 0) : Direction(dx: 0, dy: 1)
        let aIsLeft: Bool
        if let fromLowEnd = leftOf(a, b, walking: canonical.reversed) {
            aIsLeft = !fromLowEnd
        } else if let fromHighEnd = leftOf(a, b, walking: canonical) {
            aIsLeft = fromHighEnd
        } else {
            let aFirst = routes[a.route].request.id.uuidString < routes[b.route].request.id.uuidString
            let lead = aFirst ? a : b
            let points = routes[lead.route].points
            let leadTravelsCanonical = Direction(from: points[lead.index], to: points[lead.index + 1]) == canonical
            aIsLeft = aFirst ? leadTravelsCanonical : !leadTravelsCanonical
        }
        // Left of +x is up (smaller y); left of +y is +x (larger x).
        return a.horizontal ? aIsLeft : !aIsLeft
    }

    /// Whether `a` is left of `b` relative to `start`, read where the two
    /// routes part walking from their segments in direction `start`; nil
    /// when both end (at their ports) without parting.
    private func leftOf(_ a: Segment, _ b: Segment, walking start: Direction) -> Bool? {
        let tol = MissionMapRouter.tolerance
        let pa = routes[a.route].points
        let pb = routes[b.route].points
        func end(of segment: Segment, in points: [CGPoint]) -> (index: Int, step: Int) {
            let travel = Direction(from: points[segment.index], to: points[segment.index + 1])
            return travel == start ? (segment.index + 1, 1) : (segment.index, -1)
        }
        var (ia, sa) = end(of: a, in: pa)
        var (ib, sb) = end(of: b, in: pb)
        var travel = start
        while true {
            let na = ia + sa
            let nb = ib + sb
            let aContinues = na >= 0 && na < pa.count
            let bContinues = nb >= 0 && nb < pb.count
            guard aContinues || bContinues else { return nil }
            // One route ends at its port here while the other turns: the
            // turning one belongs on the side it turns to, or it would cut
            // across the ending one.
            guard aContinues else { return Direction(from: pb[ib], to: pb[nb]) != travel.left }
            guard bContinues else { return Direction(from: pa[ia], to: pa[na]) == travel.left }
            let turnA = Direction(from: pa[ia], to: pa[na])
            let turnB = Direction(from: pb[ib], to: pb[nb])
            if turnA != turnB {
                return turnA == travel.left
            }
            let reachA = turnA.dx != 0 ? pa[na].x : pa[na].y
            let reachB = turnB.dx != 0 ? pb[nb].x : pb[nb].y
            if abs(reachA - reachB) > tol {
                let sign = CGFloat(turnA.dx + turnA.dy)
                let aFarther = (reachA - reachB) * sign > 0
                // The farther route sits on the side it turned to.
                return (turnA == travel.left) == aFarther
            }
            travel = turnA
            ia = na
            ib = nb
        }
    }

    /// A route's points after its segments moved to `position`.
    private func rebuild(points: [CGPoint], segmentIndices: [Int], position: [CGFloat], segments: [Segment]) -> [CGPoint] {
        var out = points
        let count = segmentIndices.count
        for k in 0...count {
            if k == 0 || k == count {
                // A port: slides along its side with its segment.
                let s = segments[segmentIndices[k == 0 ? 0 : count - 1]]
                let c = position[segmentIndices[k == 0 ? 0 : count - 1]]
                out[k] = s.horizontal ? CGPoint(x: points[k].x, y: c) : CGPoint(x: c, y: points[k].y)
            } else {
                let before = segments[segmentIndices[k - 1]]
                let c0 = position[segmentIndices[k - 1]]
                let c1 = position[segmentIndices[k]]
                out[k] = before.horizontal ? CGPoint(x: c1, y: c0) : CGPoint(x: c0, y: c1)
            }
        }
        return out
    }

    /// Unions groups whose nudged segments (from different routes) lie
    /// closer than half a track apart over an overlapping range. Returns
    /// whether anything merged.
    private func mergeCollisions(
        segments: [Segment], segmentsOfRoute: [[Int]], points: [[CGPoint]], groups: inout UnionFind
    ) -> Bool {
        let tol = MissionMapRouter.tolerance
        struct Placed { let segment: Int; let route: Int; let horizontal: Bool; let coord: CGFloat; let lo: CGFloat; let hi: CGFloat }
        var placed: [Placed] = []
        for (r, indices) in segmentsOfRoute.enumerated() {
            let pts = points[r]
            for (k, s) in indices.enumerated() {
                let a = pts[k], b = pts[k + 1]
                let horizontal = segments[s].horizontal
                placed.append(Placed(
                    segment: s, route: r, horizontal: horizontal,
                    coord: horizontal ? a.y : a.x,
                    lo: horizontal ? min(a.x, b.x) : min(a.y, b.y),
                    hi: horizontal ? max(a.x, b.x) : max(a.y, b.y)
                ))
            }
        }
        placed.sort { $0.coord < $1.coord }
        let separation = trackSpacing / 2
        var merged = false
        for p in 0..<placed.count {
            var q = p + 1
            while q < placed.count, placed[q].coord - placed[p].coord < separation {
                let s = placed[p], t = placed[q]
                q += 1
                guard s.route != t.route, s.horizontal == t.horizontal else { continue }
                guard min(s.hi, t.hi) - max(s.lo, t.lo) > tol else { continue }
                // Only groups that can share a channel are merged.
                let a = segments[s.segment], b = segments[t.segment]
                guard max(a.limitLo, b.limitLo) <= min(a.limitHi, b.limitHi) else { continue }
                if groups.find(s.segment) != groups.find(t.segment) {
                    groups.union(s.segment, t.segment)
                    merged = true
                }
            }
        }
        return merged
    }
}

private struct UnionFind {
    private var parent: [Int]

    init(count: Int) { parent = Array(0..<count) }

    mutating func find(_ x: Int) -> Int {
        var root = x
        while parent[root] != root { root = parent[root] }
        var node = x
        while parent[node] != root {
            let next = parent[node]
            parent[node] = root
            node = next
        }
        return root
    }

    mutating func union(_ a: Int, _ b: Int) {
        let ra = find(a), rb = find(b)
        guard ra != rb else { return }
        // Lower index as root keeps grouping independent of union order.
        if ra < rb { parent[rb] = ra } else { parent[ra] = rb }
    }
}
