import pdfplumber
import re
import csv

def extract_high_value_deposits(pdf_path, output_csv_path, threshold=200000.00):
    """
    Parses a bank statement PDF and extracts transactions where the 
    Settlement Credit is >= the specified threshold.
    """
    
    # Regular expression to match the transaction rows based on the document's structure
    # It looks for "COMPLETED", parses references, N/A, and the specific numeric columns.
    tx_pattern = re.compile(
        r'(?P<status>COMPLETED|FAILED|PENDING)\s+'         # Transaction Status
        r'(?:(?P<term_id>[A-Z0-9]{8})\s+)?'               # Terminal ID (Optional)
        r'(?:(?P<rrn>\d{12,})\s+)?'                       # RRN (Optional)
        r'(?P<ref>[A-Za-z0-9_|\-]+)\s+'                   # Transaction Ref
        r'(?P<reversal>N/A|YES|NO)\s+'                    # Reversal Status
        r'(?P<amount>[\d,]+\.\d{2})\s+'                   # Transaction Amount
        r'(?P<debit>[\d,]+\.\d{2})\s+'                    # Settlement Debit
        r'(?P<credit>[\d,]+\.\d{2})\s+'                   # Settlement Credit  <-- TARGET
        r'(?P<bal_before>[\d,]+\.\d{2})\s+'               # Balance Before
        r'(?P<bal_after>[\d,]+\.\d{2})\s*'                # Balance After
        r'(?:(?P<charge>[\d,]+\.\d{2})\s+)?'              # Charge (Optional)
        r'(?P<remainder>.*)'                              # Beneficiary, Source, etc.
    )

    extracted_transactions = []

    print(f"Opening '{pdf_path}'...")
    try:
        with pdfplumber.open(pdf_path) as pdf:
            for page_num, page in enumerate(pdf.pages, start=1):
                # Extract text preserving horizontal layout to keep rows intact
                text = page.extract_text(layout=True)
                if not text:
                    continue
                
                lines = text.split('\n')
                
                for i, line in enumerate(lines):
                    match = tx_pattern.search(line)
                    if match:
                        data = match.groupdict()
                        
                        # Clean the Settlement Credit string and convert to float
                        credit_str = data['credit'].replace(',', '')
                        try:
                            credit_val = float(credit_str)
                        except ValueError:
                            continue
                        
                        # Filter for Deposits >= threshold (200,000)
                        if credit_val >= threshold:
                            
                            # Attempt to grab the next few lines for narration/details
                            # (As narration often spills onto the lines below)
                            narration = data['remainder'].strip()
                            for next_line in lines[i+1:i+3]:
                                # If the next line looks like a new transaction, stop looking
                                if "COMPLETED" in next_line or "AP_TRSF" in next_line:
                                    break
                                if next_line.strip():
                                    narration += " " + next_line.strip()

                            extracted_transactions.append({
                                'Page Number': page_num,
                                'Transaction Ref': data['ref'],
                                'Status': data['status'],
                                'Transaction Amount': data['amount'],
                                'Settlement Debit': data['debit'],
                                'Settlement Credit': data['credit'],
                                'Balance Before': data['bal_before'],
                                'Balance After': data['bal_after'],
                                'Additional Details & Narration': narration
                            })

    except FileNotFoundError:
        print(f"Error: The file '{pdf_path}' was not found. Please make sure it is in the same folder as this script.")
        return
    except Exception as e:
        print(f"Error reading PDF: {e}")
        return

    # Write results to CSV
    if extracted_transactions:
        print(f"Found {len(extracted_transactions)} transactions with deposits >= {threshold:,.2f}.")
        print(f"Writing to '{output_csv_path}'...")
        
        headers = [
            'Page Number', 'Transaction Ref', 'Status', 'Transaction Amount', 
            'Settlement Debit', 'Settlement Credit', 'Balance Before', 
            'Balance After', 'Additional Details & Narration'
        ]
        
        with open(output_csv_path, mode='w', newline='', encoding='utf-8') as file:
            writer = csv.DictWriter(file, fieldnames=headers)
            writer.writeheader()
            for tx in extracted_transactions:
                writer.writerow(tx)
                
        print("Done! Check your folder for the output.csv file.")
    else:
        print(f"No transactions found with a deposit of {threshold:,.2f} or above.")

if __name__ == "__main__":
    # Updated file names as requested
    INPUT_PDF = "file.pdf" 
    OUTPUT_CSV = "output.csv"
    
    extract_high_value_deposits(INPUT_PDF, OUTPUT_CSV, threshold=200000.00)