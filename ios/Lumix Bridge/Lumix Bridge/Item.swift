//
//  Item.swift
//  Lumix Bridge
//
//  Created by Elijah Bantugan on 8/28/26.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
