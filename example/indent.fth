facto(n): int ->
    if n == 0 then
        1
    else
        n * facto(n - 1)

test = {
    x: facto(5),
    ...r
}

print(test except x)
