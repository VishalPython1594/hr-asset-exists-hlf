package main

import (
	"encoding/json"
	"fmt"

	"github.com/hyperledger/fabric-contract-api-go/contractapi"
)

type SmartContract struct {
	contractapi.Contract
}

type Asset struct {
	ID    string `json:"ID"`
	Name  string `json:"Name"`
	Owner string `json:"Owner"`
}

// CreateAsset creates a new asset
func (s *SmartContract) CreateAsset(
	ctx contractapi.TransactionContextInterface,
	id string,
	name string,
	owner string,
) error {

	asset := Asset{
		ID:    id,
		Name:  name,
		Owner: owner,
	}

	assetJSON, err := json.Marshal(asset)
	if err != nil {
		return err
	}

	return ctx.GetStub().PutState(id, assetJSON)
}

// ReadAsset reads an asset
func (s *SmartContract) ReadAsset(
	ctx contractapi.TransactionContextInterface,
	id string,
) (*Asset, error) {

	assetJSON, err := ctx.GetStub().GetState(id)

	if err != nil {
		return nil, err
	}

	if assetJSON == nil {
		return nil, fmt.Errorf("asset %s does not exist", id)
	}

	var asset Asset

	err = json.Unmarshal(assetJSON, &asset)

	if err != nil {
		return nil, err
	}

	return &asset, nil
}

// =========================
// Candidate Task
// =========================
func (s *SmartContract) AssetExists(
	ctx contractapi.TransactionContextInterface,
	id string,
) (bool, error) {

	// TODO: Implement this function

	return false, nil
}