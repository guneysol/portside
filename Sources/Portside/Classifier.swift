import Foundation

/// Turns a raw command line into a friendly name ("Next.js", "Redis") and kind.
enum Classifier {
    private static let known: [(String, String, Kind)] = [
        // Web frameworks & dev servers
        ("next", "Next.js", .web), ("next-server", "Next.js", .web), ("vite", "Vite", .web),
        ("astro", "Astro", .web), ("nuxt", "Nuxt", .web), ("nuxi", "Nuxt", .web),
        ("remix", "Remix", .web), ("react-router", "React Router", .web), ("svelte-kit", "SvelteKit", .web),
        ("webpack", "Webpack", .web), ("webpack-dev-server", "Webpack", .web), ("rspack", "Rspack", .web),
        ("rsbuild", "Rsbuild", .web), ("parcel", "Parcel", .web), ("gatsby", "Gatsby", .web),
        ("storybook", "Storybook", .web), ("expo", "Expo", .web), ("ng", "Angular", .web),
        ("docusaurus", "Docusaurus", .web), ("wrangler", "Wrangler", .web), ("workerd", "Wrangler", .web),
        ("vercel", "Vercel Dev", .web), ("netlify", "Netlify Dev", .web), ("hugo", "Hugo", .web),
        ("uvicorn", "Uvicorn", .web), ("gunicorn", "Gunicorn", .web), ("hypercorn", "Hypercorn", .web),
        ("fastapi", "FastAPI", .web), ("flask", "Flask", .web), ("runserver", "Django", .web),
        ("streamlit", "Streamlit", .web), ("gradio", "Gradio", .web), ("jupyter-lab", "Jupyter", .web),
        ("jupyter", "Jupyter", .web), ("http.server", "Python HTTP", .web), ("puma", "Rails", .web),
        ("rails", "Rails", .web), ("artisan", "Laravel", .web), ("caddy", "Caddy", .web),
        ("nginx", "nginx", .web), ("http-server", "http-server", .web), ("serve", "serve", .web),
        // Databases & stores
        ("redis-server", "Redis", .database), ("valkey-server", "Valkey", .database),
        ("postgres", "PostgreSQL", .database), ("mysqld", "MySQL", .database), ("mariadbd", "MariaDB", .database),
        ("mongod", "MongoDB", .database), ("clickhouse", "ClickHouse", .database),
        ("clickhouse-server", "ClickHouse", .database), ("memcached", "Memcached", .database),
        ("elasticsearch", "Elasticsearch", .database), ("opensearch", "OpenSearch", .database),
        ("meilisearch", "Meilisearch", .database), ("typesense-server", "Typesense", .database),
        ("qdrant", "Qdrant", .database), ("cockroach", "CockroachDB", .database), ("etcd", "etcd", .database),
        ("minio", "MinIO", .database), ("influxd", "InfluxDB", .database), ("surreal", "SurrealDB", .database),
        // Local services
        ("ollama", "Ollama", .service), ("nats-server", "NATS", .service), ("temporal", "Temporal", .service),
        ("kafka", "Kafka", .service), ("localstack", "LocalStack", .service), ("supabase", "Supabase", .service),
        ("inngest", "Inngest", .service), ("mailpit", "Mailpit", .service), ("mailhog", "MailHog", .service),
        ("ngrok", "ngrok", .service), ("cloudflared", "cloudflared", .service), ("docker-proxy", "Docker", .service),
    ]
    private static let byToken = Dictionary(known.map { ($0.0, ($0.1, $0.2)) }, uniquingKeysWith: { a, _ in a })

    private static let runtimes: [String: String] = [
        "node": "Node", "bun": "Bun", "deno": "Deno", "python": "Python", "ruby": "Ruby",
        "php": "PHP", "java": "Java", "dotnet": ".NET", "beam.smp": "Erlang VM",
    ]

    private static let appServices: [(String, String)] = [
        ("/Docker.app/", "Docker"), ("/OrbStack.app/", "OrbStack"),
        ("/Rancher Desktop.app/", "Rancher Desktop"), ("/Podman Desktop.app/", "Podman"),
        ("/Postgres.app/", "PostgreSQL"), ("/DBngin.app/", "DBngin"), ("/Redis.app/", "Redis"),
    ]

    static func describe(command: String, exePath: String) -> (String, Kind) {
        if let (_, name) = appServices.first(where: { exePath.contains($0.0) }) {
            return (name, name == "PostgreSQL" || name == "Redis" ? .database : .service)
        }
        let tokens = command.split(separator: " ").map { basename($0).lowercased() }
        for token in tokens {
            if let hit = byToken[token] ?? byToken[(token as NSString).deletingPathExtension] { return hit }
        }
        let exe = basename(exePath.isEmpty ? (tokens.first ?? "") : exePath).lowercased()
        if let hit = byToken[exe] { return hit }
        let runtime = runtimeName(exe)
        return (runtime ?? basename(exePath.isEmpty ? command : exePath), .runtime)
    }

    /// "node /repo/node_modules/.bin/next dev --turbo" → "next dev --turbo"
    static func summarize(_ command: String) -> String {
        var parts = command.split(separator: " ").map(String.init)
        guard !parts.isEmpty else { return command }
        if runtimeName(basename(parts[0]).lowercased()) != nil, parts.count > 1, !parts[1].hasPrefix("-") {
            parts.removeFirst()
        }
        parts[0] = basename(parts[0])
        return parts.map(Format.abbreviatingHome).joined(separator: " ")
    }

    private static func runtimeName(_ exe: String) -> String? {
        if let r = runtimes[exe] { return r }
        return exe.hasPrefix("python") ? "Python" : nil // python3, python3.12…
    }

    private static func basename<S: StringProtocol>(_ s: S) -> String { String(s.basename) }
}
