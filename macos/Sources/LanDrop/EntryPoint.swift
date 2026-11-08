import Foundation

@main
@MainActor
struct EntryPoint {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--serve") || args.contains("--help") || args.contains("-h") {
            CLI.run(arguments: args)
            return
        }
        LanDropApp.main()
    }
}
