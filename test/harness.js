// Shared assertions. Kept tiny on purpose: the point of the pure modules is
// that they need nothing but node to check.
let passed = 0
const failures = []

function check(name, fn) {
  try {
    fn()
    passed++
  } catch (e) {
    failures.push(name + "\n    " + e.message)
  }
}

function eq(actual, expected, what) {
  const a = JSON.stringify(actual)
  const b = JSON.stringify(expected)
  if (a !== b) throw new Error((what || "value") + ": expected " + b + ", got " + a)
}

function ok(value, what) {
  if (!value) throw new Error((what || "assertion") + " was falsy")
}

function report(suite) {
  if (failures.length > 0) {
    console.error(suite + ": " + failures.length + " failed, " + passed + " passed\n")
    failures.forEach(f => console.error("  ✗ " + f))
    process.exit(1)
  }
  console.log(suite + ": " + passed + " passed")
}

module.exports = { check, eq, ok, report }
