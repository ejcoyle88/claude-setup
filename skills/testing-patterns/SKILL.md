---
name: testing-patterns
description: Testing patterns, factory functions, mocking strategies, and TDD workflow. Use when writing unit tests, creating test factories, or following TDD red-green-refactor cycle.
---

# Testing Patterns and Utilities

## Testing Philosophy

**Test-Driven Development (TDD):**
- Write failing test FIRST
- Implement minimal code to pass
- Refactor after green
- Never write production code without a failing test

**Behavior-Driven Testing:**
- Test behavior, not implementation
- Focus on public APIs and business requirements
- Avoid testing implementation details
- Use descriptive test names that describe behavior

**Factory Pattern:**
- Provide sensible defaults
- Allow overriding specific properties
- Keep tests DRY and maintainable
- Make use of Object Mother to make test code more descriptive

## Test Utilities

### Object Mothers
An object mother is a kind of class used in testing to help create example objects that you use for testing. 

Reference: https://martinfowler.com/bliki/ObjectMother.html

Example:

```c#
public class Invoice
{
    public Guid Identifier { get; init; }
    public decimal Amount { get; init; }
}

public class InvoiceObjectMother
{
    public Invoice GetZeroValueInvoice()
    {
        return new Invoice
        {
            Identifier = Guid.New(),
            Amount = 0
        };
    }

    public Invoice GetSpecificValueInvoice(int amount)
    {
        return new Invoice
        {
            Identifer = Guid.New(),
            Amount = amount
        };
    }
}

var testInvoices = new InvoiceObjectMother();
var repoMock = Substitute.For<IInvoiceRepository>();
repoMock.GetInvoice().Returns(testInvoices.GetZeroValueInvoice());
```


## Best Practices

1. **Test behavior, not implementation**
2. **Use descriptive test names with the Given When Then format**
3. **Organize with the Arrange Act Assert pattern**
5. **Keep test methods pure to avoid shared state**
6. **Keep tests focused** - one behavior per test

## Integration with Other Skills

- **systematic-debugging**: Write test that reproduces bug before fixing

