//
//  main.swift
//  TrellisCore
//
//  Created by Ben Colson on 06/10/2026.
//

import Foundation
import TrellisCLIKit

let result = TrellisCLI.run(Array(CommandLine.arguments.dropFirst()))
if !result.stdout.isEmpty {
    FileHandle.standardOutput.write(Data(result.stdout.utf8))
}
if !result.stderr.isEmpty {
    FileHandle.standardError.write(Data(result.stderr.utf8))
}
exit(result.code)