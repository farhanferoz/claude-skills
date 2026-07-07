# Java Security Patterns

## Framework Detection

| Indicator | Framework |
|-----------|-----------|
| `@Controller`, `@RestController`, `org.springframework` | Spring / Spring Boot |
| `javax.ws.rs`, `jakarta.ws.rs`, `@Path` | JAX-RS (Jakarta EE) |
| `@Entity`, `javax.persistence`, `jakarta.persistence` | JPA / Hibernate |
| `org.apache.struts` | Struts |
| `com.fasterxml.jackson` | Jackson (JSON) |

---

## Deserialization

### Always Flag (Critical)

```java
// FLAG: Native Java deserialization of untrusted data
ObjectInputStream ois = new ObjectInputStream(untrustedInputStream);
Object obj = ois.readObject(); // arbitrary gadget-chain RCE if classpath has known gadgets

// FLAG: Jackson polymorphic deserialization enabled globally
ObjectMapper mapper = new ObjectMapper();
mapper.enableDefaultTyping(); // deprecated but still seen; allows attacker to specify class
mapper.activateDefaultTyping(BasicPolymorphicTypeValidator.builder().build(),
    ObjectMapper.DefaultTyping.NON_FINAL); // still dangerous without a strict allowlist

// FLAG: XStream without a security framework configured
XStream xstream = new XStream();
xstream.fromXML(untrustedXml); // RCE via gadget chains unless setupDefaultSecurity() is set

// FLAG: SnakeYAML with the unsafe Constructor
Yaml yaml = new Yaml(); // default Constructor instantiates arbitrary types from tags
yaml.load(untrustedYaml);
```

### Safe Patterns (Do Not Flag)

```java
// SAFE: Jackson with a specific, non-polymorphic target type and no default typing
ObjectMapper mapper = new ObjectMapper();
MyDto dto = mapper.readValue(json, MyDto.class);

// SAFE: SnakeYAML with SafeConstructor
Yaml yaml = new Yaml(new SafeConstructor(new LoaderOptions()));

// SAFE: XStream with an explicit allowlist
xstream.addPermission(new ExplicitTypePermission(new Class[]{MyDto.class}));
```

---

## XXE (XML External Entities)

### Flag These

```java
// FLAG: DocumentBuilderFactory without disabling external entities
DocumentBuilderFactory dbf = DocumentBuilderFactory.newInstance();
DocumentBuilder db = dbf.newDocumentBuilder(); // DOCTYPE + external entities allowed by default
Document doc = db.parse(untrustedInputStream);

// FLAG: SAXParserFactory / XMLReader without hardening
SAXParserFactory spf = SAXParserFactory.newInstance();
SAXParser parser = spf.newSAXParser();

// FLAG: XMLInputFactory (StAX) without disabling DTDs
XMLInputFactory xif = XMLInputFactory.newInstance();
XMLStreamReader reader = xif.createXMLStreamReader(untrustedInputStream);

// FLAG: Transformer / XPath evaluating untrusted XML with external entity support enabled
```

### Safe Patterns (Do Not Flag)

```java
// SAFE: External entities and DOCTYPE disabled
DocumentBuilderFactory dbf = DocumentBuilderFactory.newInstance();
dbf.setFeature("http://apache.org/xml/features/disallow-doctype-decl", true);
dbf.setFeature("http://xml.org/sax/features/external-general-entities", false);
dbf.setFeature("http://xml.org/sax/features/external-parameter-entities", false);
dbf.setXIncludeAware(false);
dbf.setExpandEntityReferences(false);

// SAFE: StAX with DTD support disabled
xif.setProperty(XMLInputFactory.SUPPORT_DTD, false);
xif.setProperty(XMLInputFactory.IS_SUPPORTING_EXTERNAL_ENTITIES, false);
```

---

## JNDI Injection / Log4Shell-Class Issues

### Flag These

```java
// FLAG: Untrusted input logged through a vulnerable log4j version (< 2.17.1) or without
// message-lookup substitution disabled — check pom.xml/build.gradle for log4j-core version
logger.info(userSuppliedInput); // if log4j is vulnerable, ${jndi:ldap://...} in input triggers lookup

// FLAG: Direct JNDI lookup with an attacker-controlled name
Context ctx = new InitialContext();
Object obj = ctx.lookup(userControlledName); // arbitrary remote class loading via ldap://, rmi://

// FLAG: Any use of a naming/context provider URL built from request data
Hashtable<String, String> env = new Hashtable<>();
env.put(Context.PROVIDER_URL, userSuppliedUrl); // attacker points JNDI at their own server
```

### Framework Mitigation Notes

| Pattern | Why It's Usually Safe |
|---------|----------------------|
| `log4j-core >= 2.17.1` | Message lookups disabled by default post-patch |
| `log4j2.formatMsgNoLookups=true` set | Explicitly disables the vulnerable behavior |
| `logger.info("static message: {}", userInput)` with parameterized logging on a patched version | Value substitution, not string interpolation |

Check the actual `log4j-core`/`log4j-api` version in the dependency tree before flagging log statements — this is a version question, not just a pattern-match.

---

## SSRF

### Flag These

```java
// FLAG: URL/HttpClient request built from user input with no allowlist
URL url = new URL(request.getParameter("url"));
HttpURLConnection conn = (HttpURLConnection) url.openConnection();
conn.getInputStream();

// FLAG: RestTemplate / WebClient calling a user-supplied URL
restTemplate.getForObject(userSuppliedUrl, String.class);
webClient.get().uri(userSuppliedUrl).retrieve();

// FLAG: Apache HttpClient with a user-controlled target host
HttpGet request = new HttpGet(userControlledUrl);
httpClient.execute(request);
```

### Safe Patterns (Do Not Flag)

```java
// SAFE: URL comes from application configuration
restTemplate.getForObject(env.getProperty("internal.api.url"), String.class);

// SAFE: Destination validated against an allowlist of hosts before the request
if (!ALLOWED_HOSTS.contains(new URL(userSuppliedUrl).getHost())) {
    throw new IllegalArgumentException("host not allowed");
}
```

---

## SQL Injection

### Safe Patterns (Do Not Flag)

```java
// SAFE: PreparedStatement with bound parameters
PreparedStatement ps = conn.prepareStatement("SELECT * FROM users WHERE id = ?");
ps.setInt(1, userId);

// SAFE: JPA named/positional parameters
em.createQuery("SELECT u FROM User u WHERE u.id = :id").setParameter("id", userId);

// SAFE: Spring Data derived/JPQL query methods
userRepository.findByUsername(username);
```

### Flag These

```java
// FLAG: Statement.execute with concatenated SQL
Statement stmt = conn.createStatement();
stmt.executeQuery("SELECT * FROM users WHERE name = '" + userInput + "'");

// FLAG: JPQL/HQL built with string concatenation
em.createQuery("SELECT u FROM User u WHERE u.name = '" + userInput + "'");

// FLAG: MyBatis ${} substitution (unescaped) instead of #{} (bound parameter)
// XML mapper: SELECT * FROM users WHERE name = '${name}'  -- FLAG
// XML mapper: SELECT * FROM users WHERE name = #{name}    -- SAFE
```

---

## Spring / Jakarta Framework Mitigations

| Pattern | Why It's Usually Safe | Only Flag When |
|---------|----------------------|-----------------|
| `@RequestMapping`/`@GetMapping` path variables bound to typed method params | Spring performs type conversion, not raw string passthrough | The typed value is then concatenated into a raw query/command |
| Thymeleaf `th:text="${var}"` | HTML-escaped by default | `th:utext` is used with user input |
| `@Valid`/`@Validated` with Bean Validation annotations on request DTOs | Framework rejects invalid input before the handler runs | Validation is present but the field used downstream isn't the validated one |
| Spring Security `@PreAuthorize`/method security | Enforced by an AOP interceptor before the method body runs | The check references a role that's never actually assigned correctly (verify separately) |
| `RestTemplate`/`WebClient` calling `application.yml`-configured URLs | Server-controlled configuration | The base URL is concatenated with unvalidated user-controlled path/query data |

---

## General Java

### Always Flag

```java
// Command injection
Runtime.getRuntime().exec(userInput);
ProcessBuilder pb = new ProcessBuilder("sh", "-c", userInput);

// Path traversal
new File(baseDir, userSuppliedFileName); // check containment against baseDir after canonicalization
Files.newInputStream(Paths.get(userSuppliedPath));

// Reflection-based instantiation from user input
Class.forName(userSuppliedClassName).newInstance(); // arbitrary class loading
```

### Check Context

```java
// Weak crypto
MessageDigest.getInstance("MD5");  // FLAG if used for passwords or integrity of sensitive data
Cipher.getInstance("AES/ECB/PKCS5Padding"); // FLAG: ECB mode leaks structure

// Hardcoded secrets
private static final String SECRET_KEY = "hardcoded-value"; // FLAG if committed
```

---

## Grep Patterns

```bash
# Native deserialization
grep -rn "ObjectInputStream\|readObject()" --include="*.java"

# Unsafe XML parsing (missing hardening)
grep -rn "DocumentBuilderFactory\|SAXParserFactory\|XMLInputFactory" --include="*.java"

# JNDI lookups
grep -rn "InitialContext\|\.lookup(" --include="*.java"

# SQL string concatenation
grep -rn "createStatement()\|executeQuery(.*+\|createQuery(.*+" --include="*.java"

# MyBatis unescaped substitution
grep -rn '\${' --include="*.xml" | grep -i mapper

# Command execution
grep -rn "Runtime.getRuntime().exec\|ProcessBuilder(" --include="*.java"

# log4j version pin (verify against dependency lock, not just presence)
grep -rn "log4j-core" pom.xml build.gradle build.gradle.kts 2>/dev/null
```
