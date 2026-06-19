List<Account> accts = new List<Account>();

String[] industries = new String[]{
    'Technology','Finance','Healthcare','Retail','Manufacturing',
    'Education','Energy','Transportation','Hospitality','Real Estate'
};

for (Integer i = 1; i <= 50; i++) {
    Account a = new Account(
        Name = 'Test Account ' + i,
        Industry = industries[Math.mod(i, industries.size())],
        Phone = '(' + String.valueOf(Math.mod(i, 900) + 100) + ') ' +
                String.valueOf(Math.mod(i * 37, 900) + 100) + '-' +
                String.valueOf(Math.mod(i * 91, 9000) + 1000),
        BillingStreet = '123' + i + ' Main St',
        BillingCity = 'City ' + i,
        BillingState = 'CA',
        BillingPostalCode = String.valueOf(90000 + i),
        BillingCountry = 'USA',
        AnnualRevenue = (Decimal.valueOf(i) * 100000)
    );
    accts.add(a);
}

insert accts;

System.debug('Inserted ' + accts.size() + ' test Accounts.');
