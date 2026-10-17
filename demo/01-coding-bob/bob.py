def response(hey_bob):
    stripped = hey_bob.strip()
    if not stripped:
        return "Fine. Be that way!"
    is_question = stripped.endswith("?")
    # Shouting: contains at least one letter and all letters are uppercase
    is_shouting = stripped.isupper() and any(c.isalpha() for c in stripped)
    if is_question and is_shouting:
        return "Calm down, I know what I'm doing!"
    if is_shouting:
        return "Whoa, chill out!"
    if is_question:
        return "Sure."
    return "Whatever."
