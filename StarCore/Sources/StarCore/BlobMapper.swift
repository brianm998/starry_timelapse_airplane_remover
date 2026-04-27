import Foundation
import logging

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

// keeps a set of BlobMappings, outputs a list of what mappings that are connected
public class BlobMapper {
    public var mappings: Set<BlobMapping>

    public init() {
        self.mappings = Set<BlobMapping>()
    }

    public init(mappings: Set<BlobMapping>) {
        self.mappings = mappings
    }

    // outputs a list of lists of adjecent blobs
    public var mappingLists: [[Int32]] {
        // 1) Build an adjacency list
        var graph = [Int32: Set<Int32>]()
        for m in mappings {
            graph[m.id1, default: []].insert(m.id2)
            graph[m.id2, default: []].insert(m.id1)
        }

        // 2) Track which nodes we’ve already visited
        var visited = Set<Int32>()
        var groups: [[Int32]] = []

        // 3) For each node, if not visited, BFS/DFS to collect its component
        for node in graph.keys {
            guard !visited.contains(node) else { continue }
            var stack = [node]
            var component = [Int32]()

            visited.insert(node)
            while let current = stack.popLast() {
                component.append(current)
                for neighbor in graph[current]! {
                    if !visited.contains(neighbor) {
                        visited.insert(neighbor)
                        stack.append(neighbor)
                    }
                }
            }

            // Optionally sort each component for determinism
            groups.append(component.sorted())
        }

        return groups
    }
    
    public static func + (lhs: BlobMapper, rhs: BlobMapper) -> BlobMapper {
        BlobMapper(mappings: lhs.mappings.union(rhs.mappings)) 
    }
}
