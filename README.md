## Quest Features

create_dragon_collection ( ) / create_dragon( ):

* Create a new collection of monsters
* Define their starting characteristics
* Let the Breeder know about the new monster race
* Create a new monster token based on available collection

create_sword_collection( ) / create_sword( ):

* Supply a new collection of Equipment
* Check the combine amount is met to forge a new equipment
* Create a new Equipment token from provided collection

breed_dragons( ):
* Signer of the transaction must be the owner of the NFTs
* NFTs must be from the same collection
* Blocks transfer of the NFTs for amount of time specified while creating the collection

hatch_dragon( ):
* Unlocks monsters locked for breeding if the breeding finished
* Signer of the transaction must be the owner of the NFTs
* Creates a new monster NFT with combined properties and transfers it to the owner

combine_swords( ):
* Burns amount of equipment tokens specified while creating the collection
* Tokens must be from the same collection
* Signer of the transaction must be the owner of the NFTs
* Creates a new equipment token with combined properties  

Code by chuacw / Chee-Wee Chua,  
20 June 2023.

