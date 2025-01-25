/*
This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

import Foundation
import logging

public struct NeighborLineScores: Sendable {
    let thetaScore: Double
    let rhoScore: Double
    let sizeScore: Double
    let brightnessScore: Double
    let distanceScore: Double

    public init(thetaScore: Double,
                rhoScore: Double,
                sizeScore: Double,
                brightnessScore: Double,
                distanceScore: Double)
    {
        self.thetaScore = thetaScore
        self.rhoScore = rhoScore
        self.sizeScore = sizeScore
        self.brightnessScore = brightnessScore
        self.distanceScore = distanceScore
    }
    
    public init() {
        self.thetaScore = 0
        self.rhoScore = 0
        self.sizeScore = 0
        self.brightnessScore = 0
        self.distanceScore = 0
    }
    
    public static func +(lhs: NeighborLineScores, rhs: NeighborLineScores) -> NeighborLineScores {
        NeighborLineScores(thetaScore: rhs.thetaScore + lhs.thetaScore,
                           rhoScore: rhs.rhoScore + lhs.rhoScore,
                           sizeScore: rhs.sizeScore + lhs.sizeScore,
                           brightnessScore: rhs.brightnessScore + lhs.brightnessScore,
                           distanceScore: rhs.distanceScore + lhs.distanceScore)
    }
}


