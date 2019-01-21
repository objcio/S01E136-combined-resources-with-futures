import Foundation
import PlaygroundSupport
PlaygroundPage.current.needsIndefiniteExecution = true


enum HttpMethod<Body> {
    case get
    case post(Body)
}

extension HttpMethod {
    var method: String {
        switch self {
        case .get: return "GET"
        case .post: return "POST"
        }
    }
}

struct Resource<A> {
    var urlRequest: URLRequest
    let parse: (Data) -> A?
}

extension Resource {
    func map<B>(_ transform: @escaping (A) -> B) -> Resource<B> {
        return Resource<B>(urlRequest: urlRequest) { self.parse($0).map(transform) }
    }
}

extension Resource where A: Decodable {
    init(get url: URL) {
        self.urlRequest = URLRequest(url: url)
        self.parse = { data in
            try? JSONDecoder().decode(A.self, from: data)
        }
    }
    
    init<Body: Encodable>(url: URL, method: HttpMethod<Body>) {
        urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = method.method
        switch method {
        case .get: ()
        case .post(let body):
            self.urlRequest.httpBody = try! JSONEncoder().encode(body)
        }
        self.parse = { data in
            try? JSONDecoder().decode(A.self, from: data)
        }
    }
}

extension URLSession {
    func load<A>(_ resource: Resource<A>, completion: @escaping (A?) -> ()) {
        dataTask(with: resource.urlRequest) { data, _, _ in
            completion(data.flatMap(resource.parse))
            }.resume()
    }
}

struct Episode: Codable {
    var number: Int
    var title: String
    var collection: String
}

struct Collection: Codable {
    var title: String
    var id: String
}

indirect enum CombinedResource<A> {
    case single(Resource<A>)
    case _sequence(CombinedResource<Any>, (Any) -> CombinedResource<A>)
    case _zipped(CombinedResource<Any>, CombinedResource<Any>, (Any, Any) -> A)
}

extension CombinedResource {
    var asAny: CombinedResource<Any> {
        switch self {
        case let .single(r): return .single(r.map { $0 })
        case let ._sequence(l, transform): return ._sequence(l, { x in
            transform(x).asAny
        })
        case let ._zipped(l, r, f): return ._zipped(l, r, { x, y in
            f(x, y)
        })
        }
    }
    
    func flatMap<B>(_ transform: @escaping (A) -> CombinedResource<B>) -> CombinedResource<B> {
        return CombinedResource<B>._sequence(self.asAny, { x in
            transform(x as! A)
        })
    }
    
    func map<B>(_ transform: @escaping (A) -> B) -> CombinedResource<B> {
        switch self {
        case let .single(r): return .single(r.map(transform))
        case let ._sequence(l, f):
            return ._sequence(l, { x in
                f(x).map(transform)
            })
        case let ._zipped(l, r, f):
            return CombinedResource<B>._zipped(l, r, { x, y in
                transform(f(x, y))
            })
        }
    }
    
    func zipWith<B, C>(_ other: CombinedResource<B>, _ combine: @escaping (A,B) -> C) -> CombinedResource<C> {
        return CombinedResource<C>._zipped(self.asAny, other.asAny, { x, y in
            combine(x as! A, y as! B)
        })
    }
    
    func zip<B>(_ other: CombinedResource<B>) -> CombinedResource<(A,B)> {
        return zipWith(other, { ($0, $1) })
    }
}

let episodes = Resource<[Episode]>(get: URL(string: "https://talk.objc.io/episodes.json")!)
let collections = Resource<[Collection]>(get: URL(string: "https://talk.objc.io/collections.json")!)

func loadEpisodes(_ completion: @escaping ([Episode]?) -> ()) {
    URLSession.shared.load(collections) { colls in
        guard let c = colls?.first else { completion(nil); return }
        URLSession.shared.load(episodes) { eps in
            completion(eps?.filter { $0.collection == c.id })
        }
    }
}

extension URLSession {
    func load<A>(_ resource: CombinedResource<A>, completion: @escaping (A?) -> ()) {
        switch resource {
        case let .single(r): load(r, completion: completion)
        case let ._sequence(l, transform):
            load(l) { result in
                guard let x = result else { completion(nil); return }
                self.load(transform(x), completion: completion)
            }
        case let ._zipped(l, r, transform):
            let group = DispatchGroup()
            var resultA: Any?
            var resultB: Any?
            group.enter()
            load(l) { resultA = $0; group.leave() }
            group.enter()
            load(r) { resultB = $0; group.leave() }
            group.notify(queue: .global(), execute: {
                guard let x = resultA, let y = resultB else {
                    completion(nil); return
                }
                completion(transform(x, y))
            })
        }
    }
}

//loadEpisodes { print($0) }

extension Resource {
    var c: CombinedResource<A> {
        return .single(self)
    }
    
    func compactMap<B>(_ transform: @escaping (A) -> B?) -> Resource<B> {
        return Resource<B>(urlRequest: urlRequest, parse: { data in
            self.parse(data).flatMap(transform)
        })
    }
}

let eps: CombinedResource<[String]> = collections.compactMap { $0.first }.c.flatMap { c in
    episodes.map { eps in eps.filter { ep in ep.collection == c.id } }.c
    }.map { $0.map { $0.title } }

URLSession.shared.load(eps) { print($0) }


struct Future<A> {
    typealias Callback = (A?) -> ()
    let run: (@escaping Callback) -> ()

    func flatMap<B>(_ transform: @escaping (A) -> Future<B>) -> Future<B> {
        return Future<B> { cb in
            self.run { value in
                guard let v = value else { cb(nil); return }
                return transform(v).run(cb)
            }
        }
    }
    
    func map<B>(_ transform: @escaping (A) -> B) -> Future<B> {
        return Future<B> { cb in
            self.run { value in
                cb(value.map(transform))
            }
        }
    }
    
    func compactMap<B>(_ transform: @escaping (A) -> B?) -> Future<B> {
        return Future<B> { cb in
            self.run { value in
                cb(value.flatMap(transform))
            }
        }
    }

    func zipWith<B, C>(_ other: Future<B>, _ combine: @escaping (A,B) -> C) -> Future<C> {
        return Future<C> { cb in
            let group = DispatchGroup()
            var resultA: A?
            var resultB: B?
            group.enter()
            self.run { a in resultA = a; group.leave() }
            group.enter()
            other.run { b in resultB = b; group.leave() }
            group.notify(queue: .global(), execute: {
                guard let a = resultA, let b = resultB else {
                    cb(nil); return
                }
                cb(combine(a,b))
            })
        }
    }
}

extension URLSession {
    func future<A>(_ resource: Resource<A>) -> Future<A> {
        return Future { cb in
            self.load(resource, completion: cb)
        }
    }
}

let future = URLSession.shared.future(collections).compactMap { $0.first }.flatMap { c in
    URLSession.shared.future(episodes).map { eps in eps.filter { ep in ep.collection == c.id }}
}.map { $0.map { $0.title }}

future.run { print($0) }

URLSession.shared.future(collections).compactMap { $0.first }.zipWith(URLSession.shared.future(episodes).compactMap { $0.first }, { ($0, $1) }).run { print($0) }

//let eps2: CombinedResource<[String]> = collections.compactMap { $0.first }.c.flatMap { c in
//    episodes.map { eps in eps.filter { ep in ep.collection == c.id } }.c
//    }.map { $0.map { $0.title } }
