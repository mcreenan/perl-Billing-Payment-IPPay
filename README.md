# NAME

Billing::Payment::IPPay - IPPay Payment Provider

# SYNOPSIS

    use Billing::Payment::IPPay;

    # Create instance in test mode (uses ippay's test gateway)
    my $ippay = Billing::Payment::IPPay->new(
        test        => 1,
        terminal_id => 'TESTTERMINAL',
    );

    # Enable debugging with a custom debug handler
    my $ippay = Billing::Payment::IPPay->new(
        test        => 1,
        terminal_id => 'TESTTERMINAL',
        debug       => 1,
        debug_fn    => sub {
            my ($level, $message) = @_;
            printf "[%s] %s\n", $level, $message;
        },
    );

# DESCRIPTION

Light wrapper around the IPPay REST/XML API

Provides methods for each Transaction Type as well as building the request XML payload
and parsing the response XML payload.

# METHODS

## Constructor

### Billing::Payment::IPPay->new( ... )

This class method accepts the following class parameters:

- terminal\_id

TerminalID value supplied by IPPay for your Merchant Account.

- test

Use IPPay's test gateway.

- debug

Enable debug information to be output or captured.

See [debug\_fn](http://search.cpan.org/perldoc?debug\_fn)

- debug\_fn

A function that accepts 2 parameters: level, message.

If you pass this, any debug message is sent to this function instead of printed
to STDOUT.

## Helper Methods

All helper methods return a hash with the following structure:

    {
        success    => 0|1,
        http_code  => ...,    # HTTP Response Code from IPPay
        error_code => ...,    # Only set if success = 0. Same as "ActionCode" value
                              #   in IPPay XML Response
        error      => ...,    # Friendly error message if success = 0, usually
                              #   comes directly from IPPay
        body       => ...,    # Raw HTTP request body (XML)
        data       => { ... } # XML-parsed list of data returned by IPPay
                              #   Example keys:
                              #   ActionCode
                              #   ResultText
                              #   ErrMsg
    }

### authonly

Submits an authorization only (AUTHONLY) transaction.

#### Required Fields

- CardNum

16 digit credit card number.

- CardExpMonth

2 digit expiration month.

- CardExpYear

2 digit expiration year.

- TotalAmount

Total amount to authorize, as a decimal value (e.g. 12.99).

#### Usage

    my $response = $ippay->authonly(
        {
            CardNum      => '4000300020001000',
            CardExpMonth => '11',
            CardExpYear  => '14',
            TotalAmount  => 49.00,
        }
    );

    $response->{success}
      ? printf "OK (Transaction ID: %s)", $response->{data}->{TransactionID}
      : printf "FAILED (%s)", $response->{error};

### capture

Submits a capture (CAPT) transaction, which captures a previous authorization 
request.

#### Required Fields

- TransactionID

Transaction ID from previous authonly transaction.

#### Usage

    my $response = $ippay->capture(
        {
            TransactionID => '<Transaction ID>',
        }
    );

    $response->{success}
      ? printf "OK"
      : printf "FAILED (%s)", $response->{error};

### credit

Issue a credit to refund a previous transaction.

#### Required Fields

- TransactionID

Transaction ID from previous capture or sale transaction.

#### Usage

    my $response = $ippay->credit(
        {
            TransactionID => '<Transaction ID>',
        }
    );

    $response->{success}
      ? printf "OK"
      : printf "FAILED (%s)", $response->{error};

### check

Charge a checking or savings account.

#### Required Fields

- CardName

Name for the account.

- TotalAmount

Total amount to be charged, as a decimal dollar value (e.g. 14.95).

- FeeAmount

Fee to charge for use of checking or savings account.

__Note__: This charge is __on top of__ the TotalAmount value. If you specify 14.95
for TotalAmount and 1.00 for FeeAmount, the account is charged 15.95 in total.

- ACH

Hash containing information about the checking or savings account.

    - Type (required)

    CHECKING or SAVINGS

    - AccountNumber (required)

    Account number for the checking or savings account to be charged.

    - ABA (required)

    Routing number associated with the checking or savings account to be charged.

    Defaults to 0.

    - Tokenize

    Whether or not to create and return a token associated with the checking or
    savings account. If enabled, a _TokenID_ field will be returned in the
    response.

    - SEC

    Type of security to use

    - CheckNumber

    Number on a check if checking account.

#### Usage

    my $response = $ippay->check(
        {
            CardName    => 'Test Card',
            TotalAmount => 49.00,
            FeeAmount   => 1.00,
            ACH         => {
                Type          => 'SAVINGS',
                Tokenize      => 'true',
                SEC           => 'PPD',
                AccountNumber => '11111999',
                ABA           => '071025661',
                CheckNumber   => '15',
            },
            'IndustryInfo' => {
                'Type' => 'ECOMMERCE',
            },
        }
    );

    $response->{success}
      ? printf "OK"
      : printf "FAILED (%s)", $response->{error};

### enq

Request information about a previous transaction.

#### Required Fields

- TransactionID

transaction id from previous capture or sale transaction.

#### Usage

    use Data::Dumper;

    my $response = $ippay->enq(
        {
            TransactionID => '<transaction id>',
        }
    );

    $response->{success}
      ? printf "Ok", dumper($response->{data})
      : printf "Failed (%s)", $response->{error};

### ping

Transaction simply to verify the IPPay service is responsive

#### Usage

    my $response = $ippay->ping;
    $response->{success}
      ? printf "Ok", $response->{data}->{ResponseText}
      : printf "Failed (%s)", $response->{error};

### reversal

Reverses a previous CHECK transaction

#### Required Fields

- TransactionID

Transaction id from previous capture or sale transaction.

#### Usage

    my $response = $ippay->reversal(
        {
            TransactionID => '<transaction id>',
        }
    );

    $response->{success}
      ? printf "Ok"
      : printf "Failed (%s)", $response->{error};

### sale

Equivalent to submitted an authorization (AUTHONLY) and capture (CAPT) 
transaction.

#### Required Fields

- CardNum

16 digit credit card number.

- CardExpMonth

2 digit expiration month.

- CardExpYear

2 digit expiration year.

- TotalAmount

Total amount to authorize, as a decimal value (e.g. 12.99).

#### Usage

    my $response = $ippay->sale(
        {
            CardNum      => '4000300020001000',
            CardExpMonth => '11',
            CardExpYear  => '14',
            TotalAmount  => 49.00,
        }
    );

    $response->{success}
      ? printf "OK (Transaction ID: %s)", $response->{data}->{TransactionID}
      : printf "FAILED (%s)", $response->{error};

### tokenize

Create a unique Token idenfier that can be used in later transactions in place
of a credit card number or checking/savings account

#### Required Fields

- CardNum

16 digit credit card number.

- CardExpMonth

2 digit expiration month.

- CardExpYear

2 digit expiration year.

#### Usage

    my $response = $ippay->tokenize(
        {
            CardNum      => '4000300020001000',
            CardExpMonth => '11',
            CardExpYear  => '14',
        }
    );

    $response->{success}
      ? printf "OK (Token ID: %s)", $response->{data}->{TokenID}
      : printf "FAILED (%s)", $response->{error};

### void

Voids a credit card transaction before it has been settled (e.g. Card has been 
authorized but not captured yet)

#### Required Fields

- TransactionID

Transaction id from previous capture or sale transaction.

- TotalAmount

The amount authorized in the transaction being voided

#### Usage

    my $response = $ippay->void(
        {
            TransactionID => '<transaction id>',
            TotalAmount   => 14.95,
        }
    );

    $response->{success}
      ? printf "Ok"
      : printf "Failed (%s)", $response->{error};

### voidach

Voids a previous check transaction before it has been settled

This transactions requires and accepts all the same fields as the previous
check transaction.

#### Usage

    my $response = $ippay->voidach(
        {
            CardName    => 'Test Card',
            TotalAmount => 49.00,
            FeeAmount   => 1.00,
            ACH         => {
                Type          => 'SAVINGS',
                Tokenize      => 'true',
                SEC           => 'PPD',
                AccountNumber => '11111999',
                ABA           => '071025661',
                CheckNumber   => '15',
            },
            'IndustryInfo' => {
                'Type' => 'ECOMMERCE',
            },
        }
    );

    $response->{success}
      ? printf "Ok"
      : printf "Failed (%s)", $response->{error};







## Other Methods

### submit\_transaction

Submit a raw transaction to the IPPay API. It is __recommended__ that you use the
various helper methods instead.

# NOTE

## Unimplemented Transactions

- ACK
- FORCE
- REVERSEAUTH

# COMPATIBILITY

Compatible with IPPay's XML Product Specification v1.1.6 (Apr 30 2012)

# COPYRIGHT

Copyright 2013 Matt Creenan

This package is free software. You may redistribute it or modify it under
the same terms as Perl itself.

# AUTHORS

Matt Creenan <mattcreenan@gmail.com>

# SEE ALSO

- [http://www.ippay.com/downloads/IPPay\_Reference\_Manual.pdf](http://www.ippay.com/downloads/IPPay\_Reference\_Manual.pdf)
- IPPay XML Product Specification v1.1.6 (no link available)
- IPPay XML Feature Description for ACH Processing v1.3 (no link available)
- IPPay Test System and Back-end Simulators v1.3 (no link available)


